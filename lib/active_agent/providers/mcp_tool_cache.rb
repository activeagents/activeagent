# frozen_string_literal: true

require "monitor"
require "active_support/core_ext/object/deep_dup"

module ActiveAgent
  module Providers
    # Process-local cache for the tools an MCP server advertises.
    #
    # Asking a server what it offers is a round trip, and an expensive one: a
    # hosted server measures ~450ms for `tools/list` on top of ~680ms for the
    # handshake. The answer changes about as often as the server is redeployed,
    # so a generation that pays that to relearn the same 27 tool names is paying
    # it for nothing.
    #
    # With an entry cached, {MCPBridge} needs no connection at all to advertise
    # the tools — it connects only if the model actually calls one. So the cost
    # becomes zero for a generation that never reaches for an MCP tool, and one
    # connection for a generation that does.
    #
    # Entries hold plain data: no sockets, no child processes, no class
    # references. That is what makes it safe to hold across a fork — a child
    # gets a copy-on-write snapshot with nothing in it bound to the parent's
    # file descriptors or threads.
    #
    # @see ActiveAgent::Providers::MCPBridge
    class MCPToolCache
      # Seconds an entry stays usable. Long enough to cover a burst of
      # generations, short enough that a redeployed server is picked up on its
      # own without a restart.
      DEFAULT_TTL = 300

      # Upper bound on entries, oldest evicted first. Each entry is one server's
      # tool schemas, so this is small; the cap exists to keep a process that
      # talks to many distinct servers from growing without bound.
      DEFAULT_MAX_ENTRIES = 100

      @monitor = Monitor.new

      class << self
        # @return [Numeric] seconds an entry stays usable
        def ttl = @ttl ||= DEFAULT_TTL

        # @param seconds [Numeric] must be positive, or nothing would ever be
        #   reused
        # @return [Numeric]
        def ttl=(seconds)
          unless seconds.is_a?(Numeric) && seconds.positive?
            fail ArgumentError, "MCP tool cache ttl must be a positive number of seconds, got #{seconds.inspect}."
          end

          @ttl = seconds
        end

        # @return [Integer] entries kept before the oldest is evicted
        def max_entries = @max_entries ||= DEFAULT_MAX_ENTRIES

        # @param count [Integer]
        # @return [Integer]
        def max_entries=(count)
          unless count.is_a?(Integer) && count.positive?
            fail ArgumentError, "MCP tool cache max_entries must be a positive Integer, got #{count.inspect}."
          end

          @max_entries = count
        end

        # @return [Boolean] whether lookups consult the cache at all
        def enabled? = @enabled.nil? ? true : @enabled

        # @param value [Boolean]
        # @return [Boolean]
        def enabled=(value)
          @enabled = !!value
        end

        # @param ttl [Numeric, nil]
        # @param max_entries [Integer, nil]
        # @param enabled [Boolean, nil]
        # @return [Class] self, for chaining
        def configure(ttl: nil, max_entries: nil, enabled: nil)
          self.ttl         = ttl if ttl
          self.max_entries = max_entries if max_entries
          self.enabled     = enabled unless enabled.nil?

          self
        end

        # The cached tools for +key+, computing and storing them on a miss.
        #
        # The block runs outside the lock: it performs network I/O, and holding
        # the lock across it would serialise every generation in the process.
        # Two threads racing on the same cold key both fetch and the later write
        # wins — a duplicated round trip costs less than a global lock on the
        # latency path.
        #
        # @param key [String] identifies the declaration, e.g. a digest
        # @param enabled [Boolean, nil] per-generation override; nil uses the
        #   process-level setting
        # @yieldreturn [Array<Hash>] the tools to cache when there is no entry
        # @return [Array<Hash>] a copy the caller may mutate freely
        def fetch(key, enabled: nil)
          use_cache = enabled.nil? ? enabled? : enabled
          return yield.deep_dup unless use_cache

          cached = read(key)
          return cached if cached

          tools = yield
          write(key, tools)
          tools.deep_dup
        end

        # Drops one entry, so the next lookup asks the server again.
        #
        # @param key [String]
        # @return [nil]
        def invalidate(key)
          monitor.synchronize { entries.delete(key) }

          nil
        end

        # Drops every entry. For a redeploy-time hook or a test's setup.
        #
        # @return [nil]
        def clear!
          monitor.synchronize do
            entries.clear
            @hits   = 0
            @misses = 0
          end

          nil
        end

        # Empties the cache and restores the default settings.
        #
        # An application that configured the cache should not have to hand back
        # every value to get a clean slate; a test suite benefits most, since
        # the cache is process-global and outlives a single test.
        #
        # @return [nil]
        def reset!
          monitor.synchronize do
            entries.clear
            @hits        = 0
            @misses      = 0
            @ttl         = nil
            @max_entries = nil
            @enabled     = nil
          end

          nil
        end

        # @return [Hash] entry count and hit/miss counters, for a health check
        #   or to confirm the cache is doing what it should
        def stats
          monitor.synchronize { { size: entries.size, hits: @hits.to_i, misses: @misses.to_i } }
        end

        private

        # @param key [String]
        # @return [Array<Hash>, nil] a copy, or nil when absent or expired
        def read(key)
          monitor.synchronize do
            entry = entries[key]

            if entry.nil? || expired?(entry)
              # A stale entry is dropped rather than left to expire twice.
              entries.delete(key) if entry
              @misses = @misses.to_i + 1

              nil
            else
              @hits = @hits.to_i + 1

              entry[:tools].deep_dup
            end
          end
        end

        # @param key [String]
        # @param tools [Array<Hash>]
        # @return [nil]
        def write(key, tools)
          monitor.synchronize do
            # Re-inserting moves the key to the back, so eviction stays ordered
            # by write time even when a key is refreshed.
            entries.delete(key)
            entries[key] = { tools: tools.deep_dup, stored_at: monotonic, expires_at: monotonic + ttl }

            evict!
          end

          nil
        end

        # @param entry [Hash]
        # @return [Boolean]
        def expired?(entry) = entry[:expires_at] <= monotonic

        # @return [void]
        def evict!
          entries.reject! { |_, entry| expired?(entry) }

          # A Ruby Hash is insertion-ordered, so the front is the oldest write.
          entries.shift while entries.size > max_entries
        end

        # @return [Hash] insertion-ordered
        def entries = @entries ||= {}

        # Reentrant, so a future caller can nest without deadlocking. Created with the class, so two first
        # callers cannot each build their own.
        #
        # @return [Monitor]
        def monitor = @monitor

        # The monotonic clock, so an entry's lifetime is not affected by the
        # wall clock moving.
        #
        # @return [Float]
        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end

# frozen_string_literal: true

# A standalone PTY supervisor, deliberately without Rails, a logger, or a DB
# connection. The one-use FIFO carries the pasted code only in kernel memory.
# Files contain public flow state and the CLI's authorize URL, never output,
# codes, credentials, or the PKCE verifier. A separate process lets requests
# arrive at different web workers without losing the PTY.
require "pty"
require "io/console"
require "json"
require "fileutils"
require "uri"

directory, command, duration = ARGV
directory = File.expand_path(directory)
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(duration)
status_path = File.join(directory, "status.json")
fifo_path = File.join(directory, "code.pipe")
write_status = lambda do |status, url = nil|
  data = { status: status }
  data[:authorize_url] = url if url
  temporary = "#{status_path}.tmp"
  File.write(temporary, JSON.generate(data), mode: "w", perm: 0o600)
  File.rename(temporary, status_path)
end

reader = writer = pipe = nil
pid = nil
cancelled = false
completed = false
Signal.trap("TERM") { cancelled = true }
Signal.trap("INT") { cancelled = true }

begin
  File.umask(0o077)
  File.mkfifo(fifo_path, 0o600)
  pipe = File.open(fifo_path, File::RDWR | File::NONBLOCK)
  reader, writer, pid = PTY.spawn(command, "auth", "login", chdir: ENV.fetch("CLAUDE_CONFIG_DIR"))
  reader.winsize = [ 40, 4096 ]
  reader.echo = false
  write_status.call("starting")
  buffer = +""
  submitted = false
  loop do
    break if cancelled
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      write_status.call("expired")
      break
    end
    exited = Process.waitpid2(pid, Process::WNOHANG)
    if exited
      completed = exited.last.success?
      write_status.call(exited.last.success? ? "completed" : "failed")
      break
    end
    readable = IO.select([ reader, pipe ], nil, nil, 0.1)&.first || []
    if readable.include?(pipe) && !submitted
      code = pipe.read_nonblock(4096, exception: false)
      if code.is_a?(String) && code.match?(/\A[^\s\x00-\x1f\x7f]{1,2048}\n\z/)
        submitted = true
        # No subsequent PTY output is parsed or retained. Even an echoing or
        # failing CLI cannot leak this code through the public flow state.
        buffer.clear
        write_status.call("submitted")
        writer.write(code)
        writer.flush
        code.clear
      end
    end
    next unless readable.include?(reader)

    begin
      chunk = reader.read_nonblock(8192, exception: false)
      next unless chunk.is_a?(String) && !submitted

      buffer << chunk.force_encoding("UTF-8").scrub
      buffer = buffer[-32_768..] || buffer
      clean = buffer.gsub(/\e\[[0-9;?]*[A-Za-z]/, "")
      url = clean[%r{https://(?:claude\.ai|platform\.claude\.com)/oauth/authorize\?[^\s\e]+}]
      if url && URI.parse(url).query.to_s.include?("client_id=")
        write_status.call("awaiting_code", url)
      end
    rescue Errno::EIO, EOFError
      # A PTY reports EIO when the CLI exits. Reap it on the next iteration.
    end
  end
  write_status.call("cancelled") if cancelled
rescue StandardError
  write_status.call("failed") rescue nil
ensure
  # PTY.spawn gives the CLI a session/process group of its own.
  if pid
    Process.kill("TERM", -pid) rescue nil
    grace = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    until (Process.waitpid(pid, Process::WNOHANG) rescue true)
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= grace
      sleep 0.02
    end
    Process.kill("KILL", -pid) rescue nil
    Process.waitpid(pid) rescue nil
  end
  [ reader, writer, pipe ].compact.each { |io| io.close rescue nil }
  File.unlink(fifo_path) rescue nil
  # A timed-out or interrupted login may have written a partial credential.
  # Only a successfully completed CLI login may leave its config behind.
  FileUtils.rm_rf(ENV.fetch("CLAUDE_CONFIG_DIR")) unless completed
end

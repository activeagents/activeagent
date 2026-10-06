# frozen_string_literal: true

require "digest"
require "zlib"

module ActionAgent
  # Builds diffs and patches from file contents, in Ruby and with no git
  # process: the dialog's preview of a draft pull request, and the patch a
  # user downloads when publishing is not available (see
  # DraftPullRequestPublisher).
  #
  # A change is a Hash:
  #
  #   path:         relative to the repository root
  #   status:       "added", "modified" or "deleted"
  #   base_mode:    the mode before ("100644" or "100755"); nil when added
  #   mode:         the mode after; nil when deleted
  #   base_content: the bytes before; nil when added
  #   content:      the bytes after; nil when deleted
  #
  # Text is diffed line by line with three lines of context. A binary file
  # (one with a NUL byte in its first 8000, as git decides) is written as a
  # GIT binary patch holding the new content whole, which `git apply` takes.
  module SandboxPatch
    CONTEXT_LINES = 3
    # Past this many differing lines between two versions, a file's diff
    # replaces every line rather than searching for the shortest edit.
    MAX_EDIT_DISTANCE = 2_000
    NULL_ID = "0" * 40
    BINARY_PROBE_BYTES = 8_000
    # The characters git's base-85 encoding uses, in order.
    BASE85 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~"
    # The author `git am` records for a downloaded patch. The domain is
    # reserved, so nothing is ever sent there.
    PATCH_AUTHOR = "ActiveAgent sandbox <sandbox@activeagent.invalid>"
    LINE_PREFIX = { equal: " ".b, delete: "-".b, insert: "+".b }.freeze

    module_function

    # Whether git would treat +content+ as binary.
    def binary?(content)
      content.to_s.b.byteslice(0, BINARY_PROBE_BYTES).include?("\0")
    end

    # The id git gives +content+ as a blob.
    def blob_id(content)
      content = content.to_s.b
      Digest::SHA1.hexdigest("blob #{content.bytesize}\0".b + content)
    end

    # +change+ as `git diff` prints one file: the header, mode lines, the
    # index line and the hunks. Binary-encoded.
    def file_diff(change)
      path = change.fetch(:path)
      before = change[:status] == "added" ? nil : change[:base_content].to_s.b
      after = change[:status] == "deleted" ? nil : change[:content].to_s.b
      base_mode = change[:base_mode] || (before && change[:mode]) || "100644"
      mode = change[:mode] || base_mode

      out = String.new(encoding: Encoding::BINARY)
      out << "diff --git ".b << quote_path("a/#{path}") << " ".b << quote_path("b/#{path}") << "\n".b
      if before.nil?
        out << "new file mode #{mode}\n"
      elsif after.nil?
        out << "deleted file mode #{base_mode}\n"
      elsif base_mode != mode
        out << "old mode #{base_mode}\nnew mode #{mode}\n"
      end

      old_id = before ? blob_id(before) : NULL_ID
      new_id = after ? blob_id(after) : NULL_ID
      return out if old_id == new_id

      out << "index #{old_id}..#{new_id}#{" #{mode}" if before && after && base_mode == mode}\n"
      if binary?(before) || binary?(after)
        out << "GIT binary patch\n" << binary_literal(after.to_s) << "\n"
      elsif !(before.to_s.empty? && after.to_s.empty?)
        out << "--- ".b << (before ? quote_path("a/#{path}") : "/dev/null".b) << "\n".b
        out << "+++ ".b << (after ? quote_path("b/#{path}") : "/dev/null".b) << "\n".b
        out << hunks(lines(before), lines(after))
      end
      out
    end

    # A patch of every change, as `git format-patch` writes one commit:
    # `git am` applies it as a commit titled +subject+, and `git apply`
    # applies its changes to a checkout of +base_commit+.
    def format_patch(changes, subject:, base_commit:, body: nil, date: Time.now.utc)
      out = String.new(encoding: Encoding::BINARY)
      out << "From #{base_commit} Mon Sep 17 00:00:00 2001\n".b
      out << "From: #{PATCH_AUTHOR}\n".b
      out << "Date: #{date.rfc2822}\n".b
      out << "Subject: [PATCH] #{subject.to_s.gsub(/\s+/, ' ').strip}\n\n".b
      out << "#{body.to_s.strip}\n\n".b if body.present?
      out << "---\n\n".b
      changes.each { |change| out << file_diff(change) }
      out << "-- \nActiveAgent\n".b
    end

    # +path+ as git writes it in a header: quoted, with C escapes, when it
    # holds a quote, a backslash, a control character or a non-ASCII byte.
    def quote_path(path)
      bytes = path.b
      return bytes unless bytes.match?(/["\\\x00-\x1f\x7f-\xff]/n)

      escaped = bytes.each_byte.map do |byte|
        case byte
        when 0x07 then "\\a"
        when 0x08 then "\\b"
        when 0x09 then "\\t"
        when 0x0a then "\\n"
        when 0x0b then "\\v"
        when 0x0c then "\\f"
        when 0x0d then "\\r"
        when 0x22 then "\\\""
        when 0x5c then "\\\\"
        when 0x00..0x1f, 0x7f..0xff then format("\\%03o", byte)
        else byte.chr
        end
      end
      "\"#{escaped.join}\"".b
    end

    # +content+ split into lines, each keeping its newline.
    def lines(content)
      content.to_s.b.split(/(?<=\n)/n)
    end

    # The unified hunks that turn +old_lines+ into +new_lines+.
    def hunks(old_lines, new_lines)
      edits = line_edits(old_lines, new_lines)
      changed = edits.each_index.reject { |index| edits[index].first == :equal }
      return "".b if changed.empty?

      groups = changed.slice_when { |a, b| b - a > CONTEXT_LINES * 2 + 1 }.to_a
      groups.each_with_object(String.new(encoding: Encoding::BINARY)) do |group, out|
        first = [ group.first - CONTEXT_LINES, 0 ].max
        last = [ group.last + CONTEXT_LINES, edits.size - 1 ].min
        old_before = edits[0...first].count { |op, _| op != :insert }
        new_before = edits[0...first].count { |op, _| op != :delete }
        window = edits[first..last]
        old_count = window.count { |op, _| op != :insert }
        new_count = window.count { |op, _| op != :delete }

        out << "@@ -#{range(old_before, old_count)} +#{range(new_before, new_count)} @@\n".b
        window.each do |op, line|
          out << LINE_PREFIX.fetch(op) << line
          out << "\n\\ No newline at end of file\n".b unless line.end_with?("\n")
        end
      end
    end

    # "start,count" for a hunk that starts after +before+ lines. An empty
    # side names the line it would follow.
    def range(before, count)
      "#{count.zero? ? before : before + 1},#{count}"
    end

    # The edit script from +a+ to +b+, as [op, line] pairs with op :equal,
    # :delete or :insert: the shortest one (Myers' algorithm) between the
    # lines the two do not share at either end, or a whole replacement of
    # those lines past MAX_EDIT_DISTANCE.
    def line_edits(a, b)
      prefix = 0
      prefix += 1 while prefix < a.size && prefix < b.size && a[prefix] == b[prefix]
      suffix = 0
      suffix += 1 while suffix < a.size - prefix && suffix < b.size - prefix && a[-1 - suffix] == b[-1 - suffix]
      a_middle = a[prefix...(a.size - suffix)]
      b_middle = b[prefix...(b.size - suffix)]

      middle = shortest_edits(a_middle, b_middle) ||
        (a_middle.map { |line| [ :delete, line ] } + b_middle.map { |line| [ :insert, line ] })
      a.first(prefix).map { |line| [ :equal, line ] } + middle + a.last(suffix).map { |line| [ :equal, line ] }
    end

    # Myers' O(ND) shortest edit script, or nil when it is longer than
    # MAX_EDIT_DISTANCE. Each round's furthest-reaching paths are kept for
    # the walk back, as only the slice of diagonals that round could reach.
    def shortest_edits(a, b)
      n = a.size
      m = b.size
      return [] if n.zero? && m.zero?

      max = n + m
      offset = max + 1
      furthest = Array.new((2 * max) + 3, 0)
      trace = []
      found = (0..[ max, MAX_EDIT_DISTANCE ].min).any? do |d|
        trace << furthest[(offset - d - 1)..(offset + d + 1)]
        (-d..d).step(2).any? do |k|
          x = k == -d || (k != d && furthest[offset + k - 1] < furthest[offset + k + 1]) ? furthest[offset + k + 1] : furthest[offset + k - 1] + 1
          y = x - k
          while x < n && y < m && a[x] == b[y]
            x += 1
            y += 1
          end
          furthest[offset + k] = x
          x >= n && y >= m
        end
      end
      return nil unless found

      walk_back(trace, a, b)
    end

    def walk_back(trace, a, b)
      x = a.size
      y = b.size
      edits = []
      trace.each_with_index.reverse_each do |snapshot, d|
        at = ->(k) { snapshot[k + d + 1] }
        k = x - y
        previous_k = k == -d || (k != d && at.call(k - 1) < at.call(k + 1)) ? k + 1 : k - 1
        previous_x = at.call(previous_k)
        previous_y = previous_x - previous_k
        while x > previous_x && y > previous_y
          x -= 1
          y -= 1
          edits << [ :equal, a[x] ]
        end
        if d.positive?
          edits << (x == previous_x ? [ :insert, b[previous_y] ] : [ :delete, a[previous_x] ])
        end
        x = previous_x
        y = previous_y
      end
      edits.reverse
    end

    # +content+ whole, deflated and base-85 encoded the way a GIT binary
    # patch's "literal" hunk carries it.
    def binary_literal(content)
      deflated = Zlib::Deflate.deflate(content.b)
      out = "literal #{content.bytesize}\n".b
      deflated.bytes.each_slice(52) do |chunk|
        length = chunk.size <= 26 ? ("A".ord + chunk.size - 1) : ("a".ord + chunk.size - 27)
        out << length.chr << encode85(chunk) << "\n"
      end
      out
    end

    def encode85(bytes)
      bytes.each_slice(4).map do |group|
        value = group.each_with_index.sum { |byte, index| byte << (24 - (8 * index)) }
        digits = Array.new(5) do
          value, digit = value.divmod(85)
          BASE85[digit]
        end
        digits.reverse.join
      end.join
    end
  end
end

# frozen_string_literal: true

module ActiveAgent
  module Evals
    # Report#to_html: the run as one self-contained page on the dashboard's
    # design system (DesignTokens) — inline styles, no scripts, no external
    # assets — so a run's outcome can be archived next to a CI run or handed
    # to a teammate, and so the dashboard can serve the same page for a
    # persisted run.
    #
    # Same content as Report#to_markdown, laid out the way the dashboard's
    # suite card is: header and stat tiles, the MODELS panel with the judge's
    # pick and verdict, WHAT TO FIX cards from Report#fix_items, the
    # SCENARIOS matrix, and a per-scenario disclosure with every answer.
    module ReportHtml
      THEMES = %w[light dark].freeze
      ANSWER_LIMIT = 3_000
      ERROR_LIMIT = 500
      PROMPT_LIMIT = 200

      # @param theme [String, nil] "light" or "dark" pins the palette by putting
      #   `theme-light` / `theme-dark` on `<html>`; nil follows the viewer's
      #   `prefers-color-scheme`.
      def to_html(theme: nil)
        theme = theme.to_s.presence
        theme = nil unless THEMES.include?(theme)
        title = html_title

        <<~HTML
          <!doctype html>
          <html lang="en"#{%( class="theme-#{theme}") if theme}>
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{h(title)}</title>
          <style>
          #{html_styles}
          </style>
          </head>
          <body>
          <main class="page">
          #{html_header(title)}
          #{html_stat_tiles}
          <section class="card">
          #{html_models_panel}
          #{html_fixes}
          #{html_matrix}
          #{html_details}
          #{html_footer}
          </section>
          </main>
          </body>
          </html>
        HTML
      end

      private

      def h(value)
        CGI.escapeHTML(value.to_s)
      end

      def plural(count, word)
        "#{count} #{count == 1 ? word : word.pluralize}"
      end

      def fault_name(fault)
        fault.to_s.tr("_", " ")
      end

      # ≥ 1.0 success, ≥ 0.7 warning, else error — the same thresholds the
      # dashboard colors every pass ratio with.
      def tone_for(ratio)
        if ratio >= 1.0
          "success"
        elsif ratio >= 0.7
          "warning"
        else
          "error"
        end
      end

      # "openrouter/meta-llama/llama-3.1-8b" → ["llama-3.1-8b", "openrouter/meta-llama"];
      # a bare label reads its provider from the spec.
      def split_label(spec)
        label = spec.label.to_s
        slash = label.rindex("/")
        return [ label, spec.provider.to_s ] if slash.nil? || slash.zero?

        [ label[(slash + 1)..], label[0...slash] ]
      end

      def short_name(spec)
        split_label(spec).first
      end

      def model_by_label(label)
        @models.find { |spec| spec.label == label } || ModelSpec.new(label: label, provider: "", model: label)
      end

      def judge_name
        @judge&.label || "rules"
      end

      def judged_by
        verdict&.dig("judge").presence || judge_name
      end

      # Results per scenario, in run order.
      def scenario_cohorts
        @scenario_cohorts ||= @results.group_by { |result| result.scenario.key }.values
      end

      # Consecutive scenarios that share a group, in run order.
      def scenario_groups
        @scenario_groups ||= scenario_cohorts.chunk_while { |a, b| a.first.scenario.group == b.first.scenario.group }.to_a
      end

      def group_name(scenario)
        scenario.group_name.presence || scenario.group.presence
      end

      def anchor(scenario)
        "scenario-#{scenario.key.to_s.gsub(/[^\w-]+/, '-')}"
      end

      def fmt_k(value)
        n = value.to_f
        if n.abs >= 1_000_000
          format("%.1fM", n / 1_000_000)
        elsif n.abs >= 1_000
          format("%.1fK", n / 1_000)
        else
          n.round.to_s
        end
      end

      def fmt_ms(ms)
        return "—" if ms.nil?

        n = ms.to_f
        return "#{n.round}ms" if n < 1_000

        "#{format("%.#{n >= 10_000 ? 1 : 2}f", n / 1_000).sub(/\.?0+\z/, '')}s"
      end

      def fmt_cost(value)
        value.nil? ? "—" : format("$%.4f", value)
      end

      def fmt_score(value)
        value.nil? ? "—" : format("%.2f", value)
      end

      def fmt_mean_score(value)
        value.nil? ? "—" : format("%.3f", value)
      end

      # --- page ------------------------------------------------------------

      def html_title
        "Evaluation — #{plural(scenario_cohorts.size, 'scenario')} × #{plural(@models.size, 'model')}"
      end

      def html_styles
        [
          DesignTokens.css(scope: ":root", color_scheme: "light"),
          "@media (prefers-color-scheme: dark) {",
          DesignTokens.css(scope: ":root:not(.theme-light)", tokens: DesignTokens::DARK, color_scheme: "dark"),
          "}",
          DesignTokens.css(scope: ":root.theme-dark", tokens: DesignTokens::DARK, color_scheme: "dark"),
          STYLES,
          ".mx { grid-template-columns: minmax(240px, 1.6fr) 150px repeat(#{@models.size}, minmax(170px, 1fr)); }",
          ".matrix .inner { min-width: #{390 + 185 * @models.size}px; }"
        ].join("\n")
      end

      def html_header(title)
        chips = @metadata.to_h.map { |key, value| html_chip(key, value) }
        chips << html_chip("judge", judge_name)

        <<~HEADER
          <header>
          <h1>#{h(title)}</h1>
          <div class="chips">#{chips.join}</div>
          </header>
        HEADER
      end

      def html_chip(key, value)
        %(<span class="chip"><b>#{h(key)}</b>#{h(value)}</span>)
      end

      def html_stat_tiles
        total = @results.size
        passed = @results.count(&:passed?)
        ratio = total.positive? ? passed.to_f / total : 0.0
        tiles = [
          html_tile("Scenario runs", total, "#{plural(scenario_cohorts.size, 'scenario')} × #{plural(@models.size, 'model')}"),
          html_tile("Pass rate", "#{(ratio * 100).round}%", "#{passed} / #{total} passed", tone: tone_for(ratio)),
          html_tile("Open faults", total - passed, plural(fix_items.size, "fix item")),
          html_tile("Models", @models.size, models_subline)
        ]
        %(<section class="stats">#{tiles.join}</section>)
      end

      def html_tile(label, value, sub, tone: nil)
        %(<div class="tile"><div class="micro">#{h(label)}</div>) +
          %(<div class="value#{" tone-#{tone}" if tone}">#{h(value)}</div><div class="sub">#{h(sub)}</div></div>)
      end

      def models_subline
        if comparing? && winner
          "judge's pick · #{short_name(model_by_label(winner))}"
        else
          @models.map { |spec| short_name(spec) }.join(" · ")
        end
      end

      # --- MODELS panel ----------------------------------------------------

      def html_models_panel
        blocks = summary_by_model.map { |label, stats| html_model_block(label, stats) }
        verdict_row = verdict ? %(<div class="verdict"><span class="micro sm">Verdict</span>#{h(verdict['rationale'])}</div>) : ""

        <<~PANEL
          <div class="panel">
          <div class="panel-head"><span class="micro">Models</span><span class="right">judged by #{h(judged_by)}</span></div>
          #{blocks.join}
          #{verdict_row}
          </div>
        PANEL
      end

      def html_model_block(label, stats)
        short, provider = split_label(model_by_label(label))
        total = stats["scenarios"]
        ratio = total.positive? ? stats["passed"].to_f / total : 0.0
        tone = tone_for(ratio)
        pick = comparing? && winner == label ? %(<span class="badge info xs">judge's pick</span>) : ""
        faults = stats["faults"].map { |fault, count| %(<span class="badge error">#{h(fault_name(fault))} ×#{count}</span>) }
        faults_html = faults.any? ? faults.join : %(<span class="clean">[+] no faults</span>)

        <<~BLOCK
          <div class="model">
          <div class="line"><span class="name">#{h(short)}</span><span class="provider">#{h(provider)}</span>#{pick}<span class="pass"><span class="bar bar-#{tone}"><span style="width:#{(ratio * 100).round}%"></span></span><span class="ratio tone-#{tone}">#{stats['passed']}/#{total}</span></span></div>
          <div class="stats-line"><span>score <b>#{h(fmt_mean_score(stats['avg_score']))}</b></span><span>latency <b>#{h(fmt_ms(stats['avg_duration_ms']))}</b></span><span class="tok"><span class="in">in</span> <b>#{h(fmt_k(stats['input_tokens']))}</b> · <span class="out">out</span> <b>#{h(fmt_k(stats['output_tokens']))}</b></span><span>cost <b>#{h(fmt_cost(stats['cost']))}</b></span></div>
          <div class="faults">#{faults_html}</div>
          </div>
        BLOCK
      end

      # --- WHAT TO FIX -----------------------------------------------------

      def html_fixes
        items = fix_items
        return "" if items.empty?

        faulted = @results.reject(&:passed?)
        meta = "#{plural(items.size, 'item')} · #{plural(faulted.size, 'fault')} across " \
               "#{plural(faulted.map { |result| result.scenario.key }.uniq.size, 'scenario')}"

        <<~FIXES
          <section class="section" aria-label="Recommendations">
          <div class="section-head"><span class="micro">What to fix</span><span class="meta">#{h(meta)}</span></div>
          <div class="fixes">#{items.map { |item| html_fix_card(item) }.join}</div>
          </section>
        FIXES
      end

      def html_fix_card(item)
        tone = item["kind"] == "instruction" ? "info" : "error"
        glyph = tone == "info" ? "[i]" : "[!]"
        title = fault_name(item["fault"]) + (item["count"].to_i > 1 ? " ×#{item['count']}" : "")

        parts = [ %(<div class="head"><span class="glyph tone-#{tone}">#{glyph}</span>) +
                  %(<span class="badge #{tone}">#{h(title)}</span><span class="scope">#{h(fix_scope(item))}</span></div>) ]
        parts << %(<p>#{h(item['recommendation'])}</p>) if item["recommendation"].present?
        parts << %(<div class="quote">“#{h(item['quote'])}”</div>) if item["quote"].present?
        parts << html_fix_tools(item) if item["tools"].any?
        parts << html_fix_server(item["server"]) if item["server"]
        parts << %(<div class="note">#{h(item['note'])}</div>) if item["note"].present?
        parts << html_fix_action(item["action"]) if item["action"]
        %(<div class="fix">#{parts.join}</div>)
      end

      def html_fix_tools(item)
        chips = item["tools"].map do |tool|
          note = tool["note"].presence
          %(<span class="tool"><b>#{h(tool['name'])}</b>#{%(<span class="note">#{h(note)}</span>) if note}</span>)
        end
        %(<div class="tools"><span class="micro sm">#{h(item['tools_label'])}</span><div class="list">#{chips.join}</div></div>)
      end

      def html_fix_server(server)
        badge =
          case server["status"]
          when "enabled" then %(<span class="badge success xs">enabled for #{h(@agent_name)}</span>)
          when "available" then %(<span class="badge warning xs">available · not enabled for #{h(@agent_name)}</span>)
          else %(<span class="badge warning xs">not enabled for #{h(@agent_name)}</span>)
          end
        %(<div class="served"><span>served by</span><b>#{h(server['name'].presence || server['key'])}</b>#{badge}</div>)
      end

      # With a route the action is a button; without one, the page can only
      # say where in the dashboard the fix lives.
      def html_fix_action(action)
        button = action["path"].present? ? %(<a class="btn" href="#{h(action['path'])}">#{h(action['label'])}</a>) : ""
        %(<div class="action">#{button}<span class="hint">#{h(action['hint'])}</span></div>)
      end

      def fix_scope(item)
        return "#{item['scenario_keys'].join(', ')} · judge suggestion" if item["kind"] == "instruction"

        labels = item["models"]
        models =
          if comparing? && labels.size == @models.size
            @models.size == 2 ? "both models" : "all models"
          else
            labels.map { |label| short_name(model_by_label(label)) }.join(", ")
          end
        "#{plural(item['scenario_keys'].size, 'scenario')} · #{models}"
      end

      # --- SCENARIOS matrix ------------------------------------------------

      def html_matrix
        columns = @models.map do |spec|
          short, provider = split_label(spec)
          %(<span class="col"><span class="name">#{h(short)}</span><span class="provider">#{h(provider)}</span></span>)
        end
        rows = [ %(<div class="mx head"><span class="micro sm">Scenario</span><span class="micro sm">Expects</span>#{columns.join}</div>) ]
        scenario_groups.each do |cohorts|
          rows << html_group_row(cohorts) if group_name(cohorts.first.first.scenario)
          cohorts.each { |cohort| rows << html_scenario_row(cohort) }
        end
        groups = scenario_groups.count { |cohorts| group_name(cohorts.first.first.scenario) }
        meta = plural(scenario_cohorts.size, "scenario")
        meta += " in #{plural(groups, 'group')}" if groups.positive?

        <<~MATRIX
          <section class="section">
          <div class="section-head"><span class="micro">Scenarios</span><span class="meta">#{h(meta)}</span></div>
          <div class="matrix"><div class="inner">#{rows.join}</div></div>
          </section>
        MATRIX
      end

      def html_group_row(cohorts)
        name = group_name(cohorts.first.first.scenario)
        passes = @models.map do |spec|
          results = cohorts.filter_map { |cohort| cohort.find { |result| result.label == spec.label } }
          passed = results.count(&:passed?)
          tone =
            if results.empty? then ""
            elsif passed == results.size then " text-success"
            elsif passed.zero? then " text-error"
            else ""
            end
          %(<span class="group-pass#{tone}">#{passed}/#{results.size} passed</span>)
        end
        %(<div class="mx group"><span class="group-name">#{h(name)}</span>) +
          %(<span class="count">#{h(plural(cohorts.size, 'scenario'))}</span>#{passes.join}</div>)
      end

      def html_scenario_row(cohort)
        scenario = cohort.first.scenario
        expects = scenario.expected_tools.map { |tool| %(<span class="expect">#{h(tool)}</span>) }.join
        cells = @models.map do |spec|
          result = cohort.find { |candidate| candidate.label == spec.label }
          result ? html_result_cell(result) : %(<div class="cell"><div class="top"><span class="muted">—</span></div></div>)
        end
        %(<div class="mx"><div><div class="key"><a href="##{h(anchor(scenario))}">#{h(scenario.key)}</a></div>) +
          %(<div class="prompt">#{h(scenario.prompt.truncate(PROMPT_LIMIT))}</div></div><div class="expects">#{expects}</div>#{cells.join}</div>)
      end

      def html_result_cell(result)
        tone = result.passed? ? "success" : "error"
        glyph = result.passed? ? "[+]" : "[!]"
        fault = result.fault ? %(<span class="f">#{h(fault_name(result.fault))}</span>) : ""
        %(<div class="cell"><div class="top"><span class="g tone-#{tone}">#{glyph}</span>) +
          %(<span class="s tone-#{tone}">#{h(fmt_score(result.score))}</span>#{fault}</div>) +
          %(<div class="calls">#{html_calls(result, empty: 'no tools called')}</div></div>)
      end

      def html_calls(result, empty:)
        calls = tool_call_labels(result)
        return %(<span>#{h(empty)}</span>) if calls.empty?

        calls.map { |label, kind| %(<span#{%( class="#{kind}") if kind}>#{h(label)}</span>) }.join
      end

      # One [label, css class] per distinct call: a call of an expected tool
      # is a hit, an errored call carries ` ✗`, repeats carry ` ×k`.
      def tool_call_labels(result)
        expected = result.scenario.expected_tools
        result.replay.tool_calls.group_by { |call| [ call["name"].to_s, call["error"] ? true : false ] }.map do |(name, errored), calls|
          label = name.dup
          label << " ✗" if errored
          label << " ×#{calls.size}" if calls.size > 1
          kind = errored ? "call-err" : (expected.include?(name) ? "call-hit" : nil)
          [ label, kind ]
        end
      end

      # --- per-scenario details --------------------------------------------

      def html_details
        return "" if scenario_cohorts.empty?

        <<~DETAILS
          <section class="section">
          <div class="section-head"><span class="micro">Details</span><span class="meta">answers and tool calls per scenario</span></div>
          <div class="details">#{scenario_cohorts.map { |cohort| html_scenario_details(cohort) }.join}</div>
          </section>
        DETAILS
      end

      def html_scenario_details(cohort)
        scenario = cohort.first.scenario
        expects = scenario.expected_tools.any? ? %(<span class="exp">expects <b>#{h(scenario.expected_tools.join(' or '))}</b></span>) : ""
        labels = @models.map(&:label)
        cards = cohort.sort_by { |result| labels.index(result.label) || labels.size }.map { |result| html_result_card(result) }

        <<~BLOCK
          <div id="#{h(anchor(scenario))}">
          <details>
          <summary><span class="chev">&gt;</span><span class="key">#{h(scenario.key)}</span><span class="prompt">#{h(scenario.prompt)}</span>#{expects}</summary>
          <div class="drill">#{cards.join}</div>
          </details>
          </div>
        BLOCK
      end

      def html_result_card(result)
        short, = split_label(result.spec)
        status =
          if result.passed? then %(<span class="badge success">passed · #{h(fmt_score(result.score))}</span>)
          elsif result.errored? then %(<span class="badge error">errored</span>)
          else %(<span class="badge error">failed · #{h(fmt_score(result.score))}</span>)
          end
        fault = result.fault ? %(<div class="fault-box"><b>[!] #{h(fault_name(result.fault))}</b> — #{h(result.summary)} #{h(result.recommendation)}</div>) : ""
        error = result.replay.error ? %(<div class="error-line">Error: #{h(result.replay.error.to_s.truncate(ERROR_LIMIT))}</div>) : ""
        answer =
          if result.replay.answer.present?
            %(<div class="answer">#{h(result.replay.answer.to_s.truncate(ANSWER_LIMIT))}</div>)
          else
            %(<div class="no-answer">answer not retained for this run</div>)
          end

        <<~CARD
          <div class="result">
          <div class="head"><span class="name">#{h(short)}</span>#{status}<span class="meta">#{h(result_meta(result))}</span></div>
          <div class="body"><div class="tools-line"><span class="micro sm">Tools</span>#{html_calls(result, empty: 'none called')}</div>#{fault}#{error}#{answer}</div>
          </div>
        CARD
      end

      def result_meta(result)
        replay = result.replay
        [
          replay.duration_ms && fmt_ms(replay.duration_ms),
          replay.total_tokens.positive? ? "#{fmt_k(replay.total_tokens)} tokens" : nil,
          replay.cost && fmt_cost(replay.cost)
        ].compact.join(" · ")
      end

      # --- footer ----------------------------------------------------------

      def html_footer
        criteria = criterion_keys.map { |key| key.to_s.tr("_", " ") }.join(" · ")
        spans = [ %(<span class="nowrap">judge #{h(judge_name)}</span>) ]
        spans << %(<span class="criteria">criteria #{h(criteria)}</span>) if criteria.present?
        spans.concat(@metadata.to_h.map { |key, value| %(<span class="nowrap">#{h(key)} #{h(value)}</span>) })
        %(<footer>#{spans.join}</footer>)
      end

      # Colors only through the token variables; radii 4 badges · 6 chips ·
      # 8 controls · 10 nested panels · 12 cards · 999 bars; no shadows.
      STYLES = <<~CSS.freeze
        * { box-sizing: border-box; }
        html, body { margin: 0; min-height: 100%; }
        body { background: var(--color-background); color: var(--color-text-primary); font-family: var(--font-text); font-size: 13px; line-height: 1.45; -webkit-font-smoothing: antialiased; }
        a { color: var(--color-info); text-decoration: none; }
        a:hover { color: var(--color-info-text); text-decoration: underline; }
        .page { max-width: 1440px; margin: 0 auto; padding: 24px; display: flex; flex-direction: column; gap: 20px; }
        .micro { font-family: var(--font-mono); font-size: 11px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--color-text-secondary); }
        .micro.sm { font-size: 10px; color: var(--color-text-muted); }
        .muted { color: var(--color-text-muted); }
        h1 { margin: 0; font-size: 24px; font-weight: 700; letter-spacing: -0.01em; }
        .chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
        .chip { display: inline-flex; align-items: center; gap: 5px; padding: 2px 8px; border-radius: 6px; background: var(--color-muted); font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); }
        .chip b { font-weight: 600; color: var(--color-text-secondary); }
        .badge { display: inline-flex; align-items: center; padding: 2px 7px; border-radius: 4px; font-family: var(--font-mono); font-size: 11px; font-weight: 600; white-space: nowrap; }
        .badge.xs { padding: 1px 6px; font-size: 10px; }
        .badge.success { background: var(--color-success-soft); color: var(--color-success-text); }
        .badge.warning { background: var(--color-warning-soft); color: var(--color-warning-text); }
        .badge.error { background: var(--color-error-soft); color: var(--color-error-text); }
        .badge.info { background: var(--color-info-soft); color: var(--color-info-text); }
        .tone-success { color: var(--color-success); }
        .tone-warning { color: var(--color-warning); }
        .tone-error { color: var(--color-error); }
        .tone-info { color: var(--color-info); }
        .text-success { color: var(--color-success-text); }
        .text-error { color: var(--color-error-text); }
        .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 16px; }
        .tile { background: var(--color-card); border: 1px solid var(--color-border); border-radius: 12px; padding: 20px; }
        .tile .value { margin-top: 8px; font-family: var(--font-mono); font-size: 32px; font-weight: 700; line-height: 1.1; }
        .tile .sub { margin-top: 8px; font-size: 13px; color: var(--color-text-secondary); }
        .card { background: var(--color-card); border: 1px solid var(--color-border); border-radius: 12px; padding: 16px; display: flex; flex-direction: column; gap: 16px; }
        .section { display: flex; flex-direction: column; gap: 10px; }
        .section-head { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
        .section-head .meta { font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); }
        .panel { border: 1px solid var(--color-border-light); border-radius: 10px; overflow: hidden; }
        .panel-head { display: flex; align-items: center; gap: 10px; padding: 8px 12px; background: var(--color-muted); }
        .panel-head .right { margin-left: auto; font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); }
        .model { padding: 10px 12px; border-top: 1px solid var(--color-border-light); display: flex; flex-direction: column; gap: 6px; }
        .model .line { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
        .model .name { font-family: var(--font-mono); font-size: 12px; font-weight: 600; }
        .model .provider { font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); }
        .model .pass { margin-left: auto; display: flex; align-items: center; gap: 10px; }
        .bar { display: inline-block; width: 120px; height: 6px; border-radius: 999px; background: var(--color-muted); overflow: hidden; }
        .bar span { display: block; height: 100%; border-radius: 999px; }
        .bar-success span { background: var(--color-success); }
        .bar-warning span { background: var(--color-warning); }
        .bar-error span { background: var(--color-error); }
        .ratio { font-family: var(--font-mono); font-size: 12px; font-weight: 600; }
        .stats-line { display: flex; gap: 14px; flex-wrap: wrap; font-family: var(--font-mono); font-size: 11px; color: var(--color-text-secondary); }
        .stats-line b { font-weight: 600; color: var(--color-text-primary); }
        .tok { white-space: nowrap; }
        .tok .in { color: var(--color-token-in); }
        .tok .out { color: var(--color-token-out); }
        .faults { display: flex; gap: 6px; flex-wrap: wrap; }
        .clean { font-family: var(--font-mono); font-size: 11px; color: var(--color-success-text); }
        .verdict { padding: 10px 12px; border-top: 1px solid var(--color-border-light); font-size: 12px; line-height: 18px; color: var(--color-text-cell); }
        .verdict .micro { margin-right: 8px; }
        .fixes { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 12px; }
        .fix { border: 1px solid var(--color-border); border-radius: 10px; padding: 12px 14px; display: flex; flex-direction: column; gap: 10px; min-width: 0; }
        .fix .head { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
        .fix .glyph { font-family: var(--font-mono); font-size: 12px; font-weight: 700; }
        .fix .scope { font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); }
        .fix p { margin: 0; font-size: 13px; line-height: 19px; color: var(--color-text-cell); }
        .fix .quote { background: var(--color-muted); border-radius: 8px; padding: 8px 10px; font-size: 12px; line-height: 18px; color: var(--color-text-cell); font-style: italic; }
        .tools { display: flex; flex-direction: column; gap: 6px; }
        .tools .list { display: flex; flex-wrap: wrap; gap: 6px; }
        .tool { display: inline-flex; align-items: center; gap: 6px; padding: 3px 8px; border-radius: 6px; border: 1px solid var(--color-border); font-family: var(--font-mono); font-size: 11px; max-width: 100%; }
        .tool b { font-weight: 600; color: var(--color-text-primary); }
        .tool .note { color: var(--color-text-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .served { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; font-size: 12px; color: var(--color-text-cell); }
        .served b { font-weight: 600; color: var(--color-text-primary); }
        .fix .note { font-size: 12px; line-height: 18px; color: var(--color-text-secondary); }
        .action { display: flex; align-items: center; gap: 10px; margin-top: auto; padding-top: 2px; flex-wrap: wrap; }
        .btn { display: inline-block; padding: 6px 12px; border-radius: 8px; font-size: 13px; font-weight: 500; color: var(--color-text-cell); border: 1px solid var(--color-border-strong); background: transparent; white-space: nowrap; }
        .btn:hover { background: var(--color-hover); color: var(--color-text-primary); text-decoration: none; }
        .hint { font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); white-space: nowrap; }
        .matrix { border: 1px solid var(--color-border-light); border-radius: 10px; overflow-x: auto; }
        .mx { display: grid; gap: 12px; padding: 10px 12px; border-top: 1px solid var(--color-border-light); }
        .mx.head { padding: 8px 12px; background: var(--color-muted); align-items: end; border-top: 0; }
        .mx.group { padding: 7px 12px; background: var(--color-background); align-items: center; }
        .mx .col { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
        .mx .col .name { font-family: var(--font-mono); font-size: 11px; font-weight: 600; color: var(--color-text-primary); }
        .mx .col .provider { font-family: var(--font-mono); font-size: 10px; color: var(--color-text-muted); }
        .group-name { font-size: 12px; font-weight: 600; }
        .count { font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); }
        .group-pass { font-family: var(--font-mono); font-size: 11px; font-weight: 600; color: var(--color-text-cell); }
        .key { font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); margin-bottom: 2px; }
        .key a { color: inherit; }
        .prompt { font-size: 13px; line-height: 18px; color: var(--color-text-primary); }
        .expects { display: flex; flex-wrap: wrap; gap: 4px; align-content: flex-start; min-width: 0; }
        .expect { font-family: var(--font-mono); font-size: 11px; padding: 2px 6px; border: 1px solid var(--color-border); border-radius: 4px; color: var(--color-text-cell); white-space: nowrap; }
        .cell { min-width: 0; display: flex; flex-direction: column; gap: 3px; }
        .cell .top { display: flex; align-items: baseline; gap: 6px; flex-wrap: wrap; font-family: var(--font-mono); font-size: 12px; }
        .cell .top .g { font-weight: 700; }
        .cell .top .s { font-weight: 600; }
        .cell .top .f { font-size: 11px; color: var(--color-error-text); }
        .calls { display: flex; flex-wrap: wrap; gap: 2px 8px; font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); }
        .call-hit { color: var(--color-success-text); font-weight: 600; }
        .call-err { color: var(--color-error); font-weight: 600; }
        .details { display: flex; flex-direction: column; gap: 8px; }
        details { border: 1px solid var(--color-border-light); border-radius: 10px; overflow: hidden; }
        summary { display: flex; align-items: center; gap: 10px; padding: 10px 12px; cursor: pointer; list-style: none; flex-wrap: wrap; }
        summary::-webkit-details-marker { display: none; }
        summary:hover { background: var(--color-hover); }
        summary .chev { font-family: var(--font-mono); font-size: 12px; color: var(--color-text-muted); display: inline-block; transition: transform 0.15s ease; }
        details[open] > summary .chev { transform: rotate(90deg); }
        summary .key { margin: 0; }
        summary .exp { margin-left: auto; font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); }
        summary .exp b { font-weight: 600; color: var(--color-text-primary); }
        .drill { border-top: 1px solid var(--color-border-light); background: var(--color-background); padding: 12px; display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 12px; }
        .result { background: var(--color-card); border: 1px solid var(--color-border-light); border-radius: 10px; overflow: hidden; min-width: 0; }
        .result .head { display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--color-border-light); flex-wrap: wrap; }
        .result .head .name { font-family: var(--font-mono); font-size: 12px; font-weight: 600; }
        .result .head .meta { margin-left: auto; font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); }
        .result .body { padding: 10px 12px; display: flex; flex-direction: column; gap: 10px; }
        .tools-line { display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); }
        .fault-box { background: var(--color-error-soft); border-radius: 8px; padding: 8px 10px; font-size: 12px; line-height: 18px; color: var(--color-error-text); }
        .fault-box b { font-family: var(--font-mono); font-weight: 700; }
        .error-line { font-family: var(--font-mono); font-size: 11px; color: var(--color-error); overflow-wrap: anywhere; }
        .answer { font-family: var(--font-text); font-size: 13px; line-height: 19px; color: var(--color-text-cell); max-height: 190px; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; }
        .no-answer { font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); }
        footer { display: flex; align-items: center; gap: 16px; flex-wrap: wrap; padding-top: 12px; border-top: 1px solid var(--color-border-light); font-family: var(--font-mono); font-size: 11px; color: var(--color-text-muted); }
        footer .criteria { min-width: 0; }
        footer .nowrap { white-space: nowrap; }
      CSS
    end
  end
end

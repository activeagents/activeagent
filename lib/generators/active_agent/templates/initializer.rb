# frozen_string_literal: true

require 'active_agent'

ActiveAgent.load_configuration(Rails.root.join('config', 'active_agent.yml'))

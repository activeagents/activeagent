# frozen_string_literal: true

module ActionAgent
  # Attaches a dashboard record to whatever the host app calls an owner.
  #
  # Each model names the associations that could own it, most preferred
  # first, and the first one the host app has actually configured wins:
  #
  #   class Agent < ApplicationRecord
  #     include Ownable
  #     owned_by :user, :account
  #   end
  #
  # So an app with users scopes agents per user, an app with only accounts
  # scopes them per account, and a single-user self-hosted install declares
  # neither association and owns everything implicitly. That ordering is
  # per-model on purpose: an app can reasonably keep agents per user while
  # keeping API keys per account, and the platform does exactly that.
  #
  # Both foreign keys exist in the engine's schema either way, so moving a
  # deployment between shapes is a configuration change, not a migration.
  module Ownable
    extend ActiveSupport::Concern

    CLASS_FOR = { account: :account_class, user: :user_class }.freeze

    class_methods do
      # Declares the candidate owners for this model, most preferred first.
      def owned_by(*candidates)
        @owner_candidates = candidates.map(&:to_sym)

        @owner_candidates.each do |candidate|
          class_name = ActionAgent.public_send(CLASS_FOR.fetch(candidate))
          next if class_name.blank?

          belongs_to candidate, class_name: class_name, optional: true
        end
      end

      def owner_candidates
        @owner_candidates || []
      end

      # The association this install owns the model through, or nil when the
      # host app configured no owner model at all.
      def owner_association
        owner_candidates.find { |c| ActionAgent.public_send(CLASS_FOR.fetch(c)).present? }
      end

      # Scopes to records owned by +owner+.
      #
      # A nil owner is read two different ways, and the difference is the
      # whole point:
      #
      #   * No owner model configured at all — the single-user self-hosted
      #     install. Nothing is owned, so everything is visible.
      #   * An owner model IS configured but did not resolve — a signed-out
      #     request, or a resolver that returned nil. Returning `all` here
      #     would hand one tenant every other tenant's records, so it
      #     returns nothing instead.
      def for_owner(owner)
        return all if owner_association.nil?
        return none if owner.nil?

        case owner_association
        when :account then where(account_id: owner.id)
        when :user then where(user_id: owner.id)
        else all
        end
      end
    end

    # The record's owner under the current configuration, or nil.
    def owner
      association = self.class.owner_association
      association && public_send(association)
    end

    # Assigns +owner+ to whichever association this install uses. A no-op
    # when the host app configured no owner model.
    def owner=(record)
      association = self.class.owner_association
      public_send(:"#{association}=", record) if association
    end
  end
end

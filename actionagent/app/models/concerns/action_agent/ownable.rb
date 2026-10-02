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
  # per-model on purpose: an app can keep agents per user while keeping API
  # keys per account. A host that configures both classes and wants the
  # account to own everything re-declares `owned_by :account, :user` on the
  # user-first models from `to_prepare`, as the hosted platform does.
  #
  # An owner is matched by its class, never by its id alone (see .for_owner):
  # the two owner tables share an id space, so `where(account_id: user.id)`
  # reads whichever account happens to share that user's id.
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
          class_name = owner_class_name(candidate)
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
        owner_candidates.find { |candidate| owner_class_name(candidate).present? }
      end

      # The class the host configured for +association+, or nil when it is
      # unset or names nothing loaded.
      def owner_class_for(association = owner_association)
        return nil if association.nil?

        owner_class_name(association)&.safe_constantize
      end

      # The class name the host configured for +association+, or nil.
      def owner_class_name(association)
        ActionAgent.public_send(CLASS_FOR.fetch(association)).presence
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
      #
      # An owner of another class than the configured one also scopes to
      # nothing. A user handed to an account-owned model is first mapped to
      # its tenant through `ActionAgent.tenant_for`, so a host that resolves
      # tenants reads that tenant's rows; without a tenant resolver the user
      # is nobody's account and reads nothing.
      def for_owner(owner)
        return all if owner_association.nil?

        owner = resolve_owner(owner)
        return none if owner.nil?

        where("#{owner_association}_id": owner.id)
      end

      # +owner+ as an instance of the configured owner class: itself when it
      # is one, its tenant when it is a user and this model is owned by
      # account, nil otherwise.
      def resolve_owner(owner)
        return nil if owner.nil?

        owner_class = owner_class_for
        return nil if owner_class.nil?
        return owner if owner.is_a?(owner_class)
        return nil unless owner_association == :account && user?(owner)

        tenant = ActionAgent.tenant_for(owner)
        tenant if tenant.is_a?(owner_class)
      end

      private

      def user?(record)
        user_class = owner_class_for(:user)
        user_class.present? && record.is_a?(user_class)
      end
    end

    # The record's owner under the current configuration, or nil.
    #
    # The belongs_to is declared when the class loads, from the
    # configuration at that moment. An owner model configured afterwards
    # (a test, or an initializer that ran late) has the column but either no
    # association or one declared for another class, so the foreign key is
    # read directly in that case.
    def owner
      association = self.class.owner_association
      return nil unless association
      return public_send(association) if owner_association_current?(association)

      owner_class = ActionAgent.public_send(CLASS_FOR.fetch(association)).safe_constantize
      owner_id = self[:"#{association}_id"]
      owner_class.find_by(id: owner_id) if owner_class && owner_id
    end

    # Assigns +owner+ to whichever association this install uses. A no-op
    # when the host app configured no owner model. The record is resolved as
    # .for_owner resolves it, so a user handed to an account-owned model
    # assigns the user's tenant, and an owner that resolves to nothing raises
    # ArgumentError rather than writing its id into another class's column.
    # Writes the foreign key directly when the association is missing or was
    # declared for another class, as #owner reads it.
    def owner=(record)
      association = self.class.owner_association
      return unless association

      record = assignable_owner(record, association)
      return public_send(:"#{association}=", record) if owner_association_current?(association)

      self[:"#{association}_id"] = record&.id
    end

    private

    def assignable_owner(record, association)
      return nil if record.nil?

      resolved = self.class.resolve_owner(record)
      return resolved if resolved

      raise ArgumentError,
            "#{self.class.name} is owned by #{association} (#{self.class.owner_class_name(association)}), " \
            "so a #{record.class.name} cannot own it. Assign the #{association} itself, or configure " \
            "ActionAgent.tenant_resolver to map a user to its account."
    end

    # Whether +association+ was declared for the class the configuration
    # names now.
    def owner_association_current?(association)
      reflection = self.class.reflect_on_association(association)
      reflection.present? && reflection.class_name == ActionAgent.public_send(CLASS_FOR.fetch(association)).to_s
    end
  end
end

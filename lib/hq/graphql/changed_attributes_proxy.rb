# frozen_string_literal: true

require "delegate"

module HQ
  module GraphQL
    # Wraps a saved ActiveRecord instance returned by a `return_copy: true` update
    # mutation, remembering which columns and associations changed since the client
    # last synced. The record itself is never altered: every method is delegated
    # untouched, and hiding the unchanged fields happens one level up, in
    # `ChangedAttributesProxy::FieldGate`, a field extension installed on every
    # field of the resource's `<Name>Copy` type.
    #
    # Hiding at the field instead of in this object matters for two reasons:
    # - association fields are resolved by loaders that batch on the underlying
    #   record, not by calling the reader on this object, so a nil reader here
    #   would not stop them;
    # - custom resolvers (`certifications(type:)`, `photo_url`...) must keep seeing
    #   real values, or they would crash or compute from artificial nils.
    #
    # It must NOT mutate the underlying record either (e.g. via
    # define_singleton_method): associations declared with `inverse_of` make
    # ActiveRecord's Preloader wire a loaded child's belongs_to straight back to
    # whichever instance triggered the preload, so other fields would silently
    # inherit the change.
    #
    # `is_a?`/`kind_of?`/`class` are overridden because SimpleDelegator doesn't
    # satisfy them by default — association loaders in this gem rely on
    # `record.is_a?(model)` and ActiveRecord's Preloader relies on `record.class`
    # to resolve reflections. Use `ChangedAttributesProxy === object` to detect a
    # proxy, since `is_a?` answers for the wrapped record.
    class ChangedAttributesProxy < SimpleDelegator
      # Hides, on a `<Name>Copy` type, the fields of a proxied record that did not
      # change. Records that are not proxies (the copy mutation, `new_<name>` root
      # queries, a full-snapshot update) resolve every field as usual.
      class FieldGate < ::GraphQL::Schema::FieldExtension
        def resolve(object:, arguments:, **_rest)
          record = object.respond_to?(:object) ? object.object : object
          if ChangedAttributesProxy === record && record.hidden_field?(field.original_name.to_s.underscore)
            nil
          else
            yield(object, arguments)
          end
        end
      end

      def self.wrap(resource, columns:, associations: [])
        new(resource, columns: columns, associations: associations)
      end

      # Builds the payload of a `return_copy: true` update mutation, once `resource`
      # has been saved.
      #
      # snapshot   - `resource.attributes` before the input was assigned.
      # attributes - the mutation's (formatted) input attributes.
      # since      - the client's `changedSince`; nil asks for a full snapshot.
      # synced_at  - captured when the mutation started; the client sends it back
      #              as the next `changedSince`.
      #
      # Over-reporting is harmless (the client gets a value it already had), while
      # under-reporting leaves a stale form, so every source is unioned:
      # - this save's own changes (`saved_changes`);
      # - columns that differ after a reload, i.e. written by callbacks or by DB
      #   triggers, which `saved_changes` never sees;
      # - associations written through nested attributes in this input;
      # - whatever the host's `config.changes_since` reports since `since`, which
      #   is where other users' and processes' changes come from.
      # When `since` is missing or the host can't answer for it, the full record is
      # returned and `changed_attributes` is nil.
      def self.payload(resource, snapshot:, attributes:, since:, synced_at:, context:)
        saved = resource.saved_changes.keys
        resource.reload
        reloaded = resource.attributes
        columns = saved | reloaded.keys.select { |key| reloaded[key] != snapshot[key] }
        associations = input_associations(resource.class, attributes)

        external =
          if since
            ::HQ::GraphQL.changes_since(
              record: resource,
              since: since,
              associations: resource.class.reflect_on_all_associations,
              context: context
            )
          end

        if external.nil?
          return { resource: resource, changed_attributes: nil, synced_at: synced_at, errors: {} }
        end

        proxy = wrap(
          resource,
          columns: columns | Array(external[:columns]).map(&:to_s),
          associations: associations | Array(external[:associations]).map(&:to_s)
        )
        {
          resource: proxy,
          changed_attributes: proxy.changed_attribute_names.map { |name| name.camelize(:lower) },
          synced_at: synced_at,
          errors: {},
        }
      end

      # Association names written by the input: `emails_attributes` (nested
      # attributes), `writing_advisor_ids` (collection ids) or a bare association key.
      def self.input_associations(klass, attributes)
        return [] unless attributes.respond_to?(:keys)

        attributes.keys.filter_map do |key|
          key = key.to_s
          candidates = [key, key.delete_suffix("_attributes")]
          candidates << key.delete_suffix("_ids").pluralize if key.end_with?("_ids")
          candidates.detect { |name| klass.reflect_on_association(name) }
        end.uniq
      end

      def initialize(resource, columns:, associations: [])
        super(resource)
        klass = resource.class
        @primary_key = klass.primary_key.to_s
        @column_names = klass.column_names.to_set
        reflections = klass.reflect_on_all_associations
        @association_names = reflections.map { |reflection| reflection.name.to_s }.to_set

        @changed_columns = columns.map(&:to_s).to_set & @column_names
        @changed_associations = associations.map(&:to_s).to_set & @association_names
        # A belongs_to changed when its foreign key did.
        reflections.each do |reflection|
          next unless reflection.belongs_to? && @changed_columns.include?(reflection.foreign_key.to_s)

          @changed_associations << reflection.name.to_s
        end
      end

      def changed_attribute_names
        (@changed_columns | @changed_associations).to_a
      end

      # Whether the field resolving `name` (a column or association name) is
      # hidden. Anything else (the primary key, custom fields) always resolves.
      def hidden_field?(name)
        return false if name == @primary_key
        return !@changed_columns.include?(name) if @column_names.include?(name)
        return !@changed_associations.include?(name) if @association_names.include?(name)

        false
      end

      delegate :class, :is_a?, :instance_of?, to: :__getobj__
      alias_method :kind_of?, :is_a?
    end
  end
end

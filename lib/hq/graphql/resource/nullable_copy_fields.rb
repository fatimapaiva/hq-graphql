# frozen_string_literal: true

require "hq/graphql/changed_attributes_proxy"

module HQ
  module GraphQL
    module Resource
      # Extended onto a resource's `<Name>Copy` type. Every field declared on it --
      # auto-generated or from the resource's `query do ... end` block -- becomes
      # nullable, and is gated so a `return_copy: true` update mutation returns null
      # for whatever did not change. A guarantee like `field :name, String, null: false`
      # only holds for the regular type, which keeps it.
      module NullableCopyFields
        def field(*args, **kwargs, &block)
          kwargs[:null] = true
          kwargs[:extensions] = [::HQ::GraphQL::ChangedAttributesProxy::FieldGate, *Array(kwargs[:extensions])]
          super(*args, **kwargs, &block)
        end
      end
    end
  end
end

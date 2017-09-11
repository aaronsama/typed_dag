require 'active_support/concern'
require 'typed_dag/configuration'

module TypedDag::Node
  extend ActiveSupport::Concern

  included do
    include InstanceMethods
    include Associations
  end

  module ClassMethods
    def _dag_options
      TypedDag::Configuration[self]
    end
  end

  module Associations
    extend ActiveSupport::Concern

    included do
      def self.dag_relations_association_lambda(column, depth = nil)
        # memoize for closure
        config = _dag_options

        -> {
          edge_table = config.edge_class_name.constantize.table_name
          column_condition = { edge_table => { column => depth } }

          condition = if depth
                        where(column_condition)
                      else
                        where.not(column_condition)
                      end

          (config.type_columns - [column]).each do |undesired_column|
            condition = condition.where(undesired_column => 0)
          end

          condition
        }
      end
      private_class_method :dag_relations_association_lambda

      has_many :relations_from,
               class_name: _dag_options.edge_class_name,
               foreign_key: _dag_options.ancestor_column,
               dependent: :destroy

      has_many :relations_to,
               class_name: _dag_options.edge_class_name,
               foreign_key: _dag_options.descendant_column,
               dependent: :destroy

      _dag_options.types.each do |key, config|
        if config[:up].is_a?(Hash) && config[:up][:limit] == 1
          has_one :"#{config[:up][:name]}_relation",
                  dag_relations_association_lambda(key, 1),
                  class_name: _dag_options.edge_class_name,
                  foreign_key: _dag_options.descendant_column

          has_one config[:up][:name],
                  through: :"#{config[:up][:name]}_relation",
                  source: :ancestor
        else
          has_many :"#{config[:up]}_relation",
                   dag_relations_association_lambda(key, 1),
                   class_name: _dag_options.edge_class_name,
                   foreign_key: _dag_options.descendant_column

          has_many config[:up],
                   through: :"#{config[:up]}_relation",
                   source: :ancestor,
                   dependent: :destroy
        end

        has_many :"#{config[:down]}_relations",
                 dag_relations_association_lambda(key, 1),
                 class_name: _dag_options.edge_class_name,
                 foreign_key: _dag_options.ancestor_column

        has_many config[:down],
                 through: :"#{config[:down]}_relations",
                 source: :descendant

        has_many :"#{config[:all_down]}_relations",
                 dag_relations_association_lambda(key),
                 class_name: _dag_options.edge_class_name,
                 foreign_key: _dag_options.ancestor_column

        has_many config[:all_down],
                 -> { distinct },
                 through: :"#{config[:all_down]}_relations",
                 source: :descendant

        has_many :"#{config[:all_up]}_relations",
                 dag_relations_association_lambda(key),
                 class_name: _dag_options.edge_class_name,
                 foreign_key: _dag_options.descendant_column

        has_many config[:all_up],
                 -> { distinct },
                 through: :"#{config[:all_up]}_relations",
                 source: :ancestor

        define_method :"#{config[:all_down]}_of_depth" do |depth|
          send(config[:all_down])
            .where(_dag_options.edge_table_name => { key => depth })
        end

        define_method :"#{config[:all_up]}_of_depth" do |depth|
          send(config[:all_up])
            .where(_dag_options.edge_table_name => { key => depth })
        end

        define_method :"self_and_#{config[:all_up]}" do
          ancestors_scope = self.class.where(id: send(config[:all_up]))
          self_scope = self.class.where(id: id)

          ancestors_scope.or(self_scope)
        end

        define_method :"self_and_#{config[:all_down]}" do
          ancestors_scope = self.class.where(id: send(config[:all_down]))
          self_scope = self.class.where(id: id)

          ancestors_scope.or(self_scope)
        end
      end
    end
  end

  module InstanceMethods
    def leaf?
      !relations_from
        .where(hierarchy: 1)
        .exists?
    end

    def child?
      !!parent_relation
    end

    def in_closure?(other_node)
      ancestor_edge(other_node)
        .or(descendant_edge(other_node))
        .exists?
    end

    def ancestor_edge(other_node)
      ancestors_relations
        .where(_dag_options.edge_table_name => { _dag_options.ancestor_column => other_node })
    end

    def descendant_edge(other_node)
      descendants_relations
        .where(_dag_options.edge_table_name => { _dag_options.descendant_column => other_node })
    end

    def _dag_options
      self.class._dag_options
    end
  end
end
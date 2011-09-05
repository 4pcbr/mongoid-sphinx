# MongoidSphinx, a full text indexing extension for MongoDB/Mongoid using
# Sphinx.

module Mongoid
  module Sphinx
    extend ActiveSupport::Concern
    included do
      unless defined?(SPHINX_TYPE_MAPPING)
        SPHINX_TYPE_MAPPING = {
          'Date' => 'timestamp',
          'DateTime' => 'timestamp',
          'Time' => 'timestamp',
          'Float' => 'float',
          'Integer' => 'int',
          'BigDecimal' => 'float',
          'Boolean' => 'bool'
        }
      end
      
      cattr_accessor :search_fields
      cattr_accessor :search_attributes
      cattr_accessor :index_options
      cattr_accessor :sphinx_index
    end
    
    module ClassMethods
      
      def search_index(options={})
        self.search_fields = options[:fields]
        self.search_attributes = {}
        self.index_options = options[:options] || {}
        options[:attributes].each do |attrib|
          self.search_attributes[attrib] = SPHINX_TYPE_MAPPING[self.fields[attrib.to_s].type.to_s] || 'str2ordinal'
        end
        
        MongoidSphinx.context.add_indexed_model self
      end
      
      def internal_sphinx_index
        self.sphinx_index ||= MongoidSphinx::Index.new(self)
      end
      
      def has_sphinx_indexes?
        self.search_fields && self.search_fields.length > 0
      end
      
      def to_riddle
        self.internal_sphinx_index.to_riddle
      end
      
      def sphinx_stream
        STDOUT.sync = true # Make sure we really stream..
        
        puts '<?xml version="1.0" encoding="utf-8"?>'
        puts '<sphinx:docset>'
        
        # Schema
        puts '<sphinx:schema>'
        puts '<sphinx:field name="classname"/>'
        self.search_fields.each do |key, value|
          puts "<sphinx:field name=\"#{key}\"/>"
        end
        self.search_attributes.each do |key, value|
          puts "<sphinx:attr name=\"#{key}\" type=\"#{value}\"/>"
        end
        puts '</sphinx:schema>'
        
        self.all.entries.each do |document|
          sphinx_compatible_id = document['_id'].to_s.to_i - 100000000000000000000000
          if sphinx_compatible_id > 0
            puts "<sphinx:document id=\"#{sphinx_compatible_id}\">"
            
            puts "<classname>#{self.to_s}</classname>"
            self.search_fields.each do |key|
              if document.respond_to?(key.to_sym)
                if document[key.to_s].is_a?(Array)
                  puts "<#{key}><![CDATA[[#{document[key.to_s].join(", ")}]]></#{key}>"
                elsif document[key.to_s].is_a?(Hash)
                  entries = []
                  document[key.to_s].to_a.each do |entry|
                    entries << entry.join(" : ")
                  end
                  puts "<#{key}><![CDATA[[#{entries.join(", ")}]]></#{key}>"
                else
                  puts "<#{key}><![CDATA[[#{document[key.to_s]}]]></#{key}>"
                end
              end
            end
            self.search_attributes.each do |key, value|
              if document.respond_to?(key.to_sym)
                value = case value
                  when 'bool' 
                    document[key.to_s] ? 1 : 0
                  when 'timestamp'
                    document[key.to_s].is_a?(Date) ? document[key.to_s].to_time.to_i : document[key.to_s].to_i
                  else 
                    if document[key.to_s].is_a?(Array)
                      document[key.to_s].join(", ")
                    elsif document[key.to_s].is_a?(Hash)
                      entries = []
                      document[key.to_s].to_a.each do |entry|                    
                        entries << entry.join(" : ")
                      end
                      entries.join(", ")
                    else
                      document[key.to_s].to_s
                    end
                end 
                puts "<#{key}>#{value}</#{key}>"
              end
            end
            
            puts '</sphinx:document>'
          end
        end
        
        puts '</sphinx:docset>'
      end
      
      def search(query, options = {})
        client = MongoidSphinx::Configuration.instance.client
        
        client.match_mode = options[:match_mode] || :extended
        client.limit = options[:limit] if options.key?(:limit)
        client.max_matches = options[:max_matches] if options.key?(:max_matches)
        
        if options.key?(:sort_by)
          client.sort_mode = :extended
          client.sort_by = options[:sort_by]
        end
        
        if options.key?(:with)
          options[:with].each do |key, value|
            client.filters << Riddle::Client::Filter.new(key.to_s, value.is_a?(Range) ? value : value.to_a, false)
          end
        end
        
        if options.key?(:without)
          options[:without].each do |key, value|
            client.filters << Riddle::Client::Filter.new(key.to_s, value.is_a?(Range) ? value : value.to_a, true)
          end
        end
        
        result = client.query("#{query} @classname #{self.to_s}")
        
        if result and result[:status] == 0 and (matches = result[:matches])
          ids = matches.collect do |row|
            (100000000000000000000000 + row[:doc]).to_s rescue nil
          end.compact
          
          return ids if options[:raw] or ids.empty?
          return self.find(ids)
        else
          return []
        end
      end
    end
    
    def search_ids(id_range, options = {})
      client = MongoidSphinx::Configuration.instance.client
      
      if id_range.is_a?(Range)
        client.id_range = id_range
      elsif id_range.is_a?(Fixnum)
        client.id_range = id_range..id_range
      else
        return []
      end
      
      client.match_mode = :extended
      client.limit = options[:limit] if options.key?(:limit)
      client.max_matches = options[:max_matches] if options.key?(:max_matches)
      
      result = client.query("* @classname #{self.to_s}")
      
      if result and result[:status] == 0 and (matches = result[:matches])
        ids = matches.collect do |row|
          (100000000000000000000000 + row[:doc]).to_s rescue nil
        end.compact
        
        return ids if options[:raw] or ids.empty?
        return self.find(ids)
      else
        return false
      end
    end    
    
    private
    def sphinx_id
      self._id.to_s.to_i - 100000000000000000000000
    end
  end
end

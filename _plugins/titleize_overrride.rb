module Jekyll
    module Utils
      def titleize_slug(slug)
        slug.split(/[_-]/).join(' ').capitalize
      end
    end
end
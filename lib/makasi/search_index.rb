module Makasi
  class SearchIndex
    MAX_LITERAL_SIZE = 4095
    MAX_TEXT_SIZE = 262144

    def reindex
      sync_db_with_sitemap
      puts "End Sync, starting parse and uploading pages"
      CloudSearchDocument.desc(:reindexed_at).each do |cloudsearch_doc|
        html_content = load_page(cloudsearch_doc.url)
        html_doc = Nokogiri::HTML(html_content)

        if Rails.logger.debug?
          Rails.logger.debug ">>> URL: "              + cloudsearch_doc.url +
                             "\n\tTITLE: "            + title_of(html_doc) +
                             "\n\tCONTENT: "          + content_of(html_doc)[0..300] +
                             "\n\tAUTHOR: "           + meta_tag_for(html_doc, "author") +
                             "\n\tCONTENT_LANGUAGE: " + language_of(html_doc) +
                             "\n\tDESCRIPTION: "      + meta_tag_for(html_doc, "description")[0..300] +
                             "\n\tKEYWORDS: "         + meta_tag_for(html_doc, "keywords") +
                             "\n\tRESOURCE_TYPE: "    + meta_tag_for(html_doc, "resource_type") +
                             "\n\tRESOURCE_NAME: "    + resource_name_of(html_doc) +
                             "\n\tRESOURCE_ID: "      + meta_tag_for(html_doc, "resource_id") +
                             "\n"
        end
        puts cloudsearch_doc.url
        add_item_to_cloudsearch(cloudsearch_doc, html_doc)

        cloudsearch_doc.update_attributes(reindexed_at: DateTime.now)
      end
    end

    def add_item_to_cloudsearch(cloudsearch_doc, html_doc)
      asari.add_item(cloudsearch_doc.url, {
        url:              cloudsearch_doc.url,
        title:            title_of(html_doc)[0..MAX_TEXT_SIZE],
        content:          content_of(html_doc)[0..MAX_TEXT_SIZE],
        author:           meta_tag_for(html_doc, "author")[0..MAX_TEXT_SIZE],
        content_language: language_of(html_doc)[0..MAX_LITERAL_SIZE],
        description:      meta_tag_for(html_doc, "description")[0..MAX_TEXT_SIZE],
        keywords:         meta_tag_for(html_doc, "keywords").split(",").map(&:strip),
        resource_type:    meta_tag_for(html_doc, "resource_type")[0..MAX_TEXT_SIZE],
        resource_name:    resource_name_of(html_doc)[0..MAX_TEXT_SIZE],
        resource_id:      meta_tag_for(html_doc, "resource_id")[0..MAX_TEXT_SIZE]
      })
    end

    def sync_db_with_sitemap
      CloudSearchDocument.update_all(present_in_sitemap: false)
      url_nodes = Nokogiri::XML(read_sitemap).css('url loc')

      url_nodes.each do |url_node|
        cloudsearch_doc = CloudSearchDocument.find_or_initialize_by(url: url_node.text.strip)
        cloudsearch_doc.update_attributes(present_in_sitemap: true)
      end

      if Rails.logger.debug?
        Rails.logger.debug "SEARCH_INDEX: Updated #{CloudSearchDocument.where(present_in_sitemap: true).count} documents"
        Rails.logger.debug "SEARCH_INDEX: Removed #{CloudSearchDocument.where(present_in_sitemap: false).count} documents"
      end

      CloudSearchDocument.where(present_in_sitemap: false).destroy_all
    end

    def load_page(url, limit = 10)
      if limit == 0
        Rails.logger.error "ERROR: Faild load sitemap's url #{url}"
        return ""
      end

       url += "/" unless url.ends_with?("/")
       if url.start_with?('https') then
        parsed_url = URI.parse(url)
        http = Net::HTTP.new(parsed_url.host, parsed_url.port)
        http.use_ssl = true
        request = Net::HTTP::Get.new(url)
        response = http.start { |http| http.request(request) }
      else
        parsed_url = URI.parse(url)
        request = Net::HTTP::Get.new(url)
        response = Net::HTTP.start(parsed_url.host, parsed_url.port) { |http| http.request(request) }
      end
      case response
      when Net::HTTPSuccess     then response.body
      when Net::HTTPRedirection then load_page(response['location'], limit - 1)
      else
        Rails.logger.error "Makasi::SearchIndex ERROR: Faild load sitemap's url #{url}"
        return ""
      end
    end

    def asari
      @asari ||= Makasi::AsariClient.new
    end

    def read_sitemap
      sitemap_file = open(Makasi::Config.sitemap_url)
      Zlib::GzipReader.new(sitemap_file).read
    end

    def meta_tag_for(doc, name)
      nodes = doc.css("meta[name='#{name}']")
      nodes.present? ? HTMLEntities.new.decode(nodes[0]["content"].to_s.strip) : ""
    end

    def title_of(doc)
      nodes = doc.xpath("//title")
      nodes.present? ? HTMLEntities.new.decode(nodes[0].text) : ""
    end

    def content_of(doc)
      content_nodes = doc.css(Makasi::Config.content_selector)
      if content_nodes.present?
        extract_text(content_nodes)
      else
        extract_text([doc])
      end
    end

    def language_of(doc)
      nodes = doc.xpath("//html")
      nodes.present? ? nodes[0]["lang"].to_s : ""
    end

    def extract_text(nodes)
      content = StringIO.new
      nodes.each do |node|
        node.traverse do |child_node|
          if child_node.text?
            content << child_node.text
          elsif child_node.name == "img"
            content << child_node["alt"]
          end
          content << " "
        end
      end
      HTMLEntities.new.decode content.string.gsub(/\s+/, " ").strip
    end

    def resource_name_of(doc)
      content_nodes = doc.css(Makasi::Config.resource_name_selector)
      if content_nodes.present?
        HTMLEntities.new.decode content_nodes.map(&:text).join(" ")
      else
        title_of(doc)
      end
    end
  end
end

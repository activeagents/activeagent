require "net/http"
require "base64"

class CatImageService
  def self.fetch_base64_image
    "data:image/jpeg;base64,#{Base64.strict_encode64(Net::HTTP.get_response(URI(fetch_image_url)).body)}"
  end

  def self.fetch_image_url
    uri = URI("https://cataas.com/cat?width=100&json=true")
    response = Net::HTTP.get_response(uri)

    if response.is_a?(Net::HTTPSuccess)
      json_response = JSON.parse(response.body)
      image_url = json_response["url"]
      image_url
    else
      raise "Failed to fetch cat image. Status code: #{response.code}"
    end
  end
end

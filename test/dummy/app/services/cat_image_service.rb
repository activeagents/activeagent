require 'net/http'
require 'base64'

class CatImageService
  def self.fetch_base64_image
    uri = URI("https://cataas.com/cat")
    response = Net::HTTP.get_response(uri)
  
    if response.is_a?(Net::HTTPSuccess)
      image_data = response.body
      "data:image/jpeg;base64,#{Base64.strict_encode64(image_data)}"
    else
      raise "Failed to fetch cat image. Status code: #{response.code}"
    end
  end
end
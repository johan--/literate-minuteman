class ScrapedBook
  attr_accessor :title, :location, :call_number, :status, :url

  def initialize(options={})
    options.each do |k,v|
      self.public_send("#{k}=", v)
    end
  end
end

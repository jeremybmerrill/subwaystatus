#!/usr/bin/env ruby
# encoding: utf-8

##
# 
# Create an email to send if one of your subway lines has service issues.
#
##

require 'nokogiri'
require 'open-uri'
require 'yaml'
require 'mail'
require 'aws-sdk'
require 'csv'

config = YAML.load(open('config.yml').read)

statuses_csv = "statuses.csv"
if File.exists?(statuses_csv)
  statuses = CSV.open(statuses_csv, 'rb').to_a.each(&:freeze)
else
  statuses = []
end

lines = config["trains"].map(&:to_s)

class String
  def slashify
    chars.join("/")
  end
end

# fetches the MTA's Service Status XML
if ENV['TEST']
  status_page = Nokogiri::XML(open(ARGV[0]).read)
else
  begin
    status_page = Nokogiri::XML(open('http://web.mta.info/status/serviceStatus.txt'))
  rescue OpenURI::HTTPError
    exit(404) if status_page == 404
  end
end

screwed = {}
maybe_screwed = {}
okay_line = nil

line_statuses = status_page.xpath('//line')

lines.each_with_index do |line, index|
  line_status = line_statuses.to_a.find{|status| Regexp.new(line) =~ status.xpath('name').text }

  status = [line_status.xpath('name').text, line_status.xpath('status').text, line_status.xpath('text').text]
  status.freeze
  statuses << status unless statuses.include?( status )

  if line_status.xpath('status').text =~ /GOOD SERVICE/
    okay_line = line
    break
  elsif line_status.xpath('status').text =~ /DELAYS/
    screwed[line] = line_status.xpath('text').text
  elsif line_status.xpath('status').text =~ /SERVICE CHANGE|PLANNED WORK/
    maybe_screwed[line] = line_status.xpath('text').text
  else
    puts line_status.xpath('status').text
  end
end

puts "Okay: #{okay_line}"
puts 

if okay_line
  if !maybe_screwed.empty?
    subject = maybe_screwed.keys.map(&:slashify).join(", ") + " may be screwed; #{okay_line.slashify} is okay"
    if !screwed.empty?
      subject += " (" + screwed.map(&:slashify).join(", ") + " " + (screwed.size > 1 ? 'are' : 'is') + " totally fucked)"
    end
    body = maybe_screwed.to_a.map{|name, text| "<h1>#{name}</h1><p>#{text.strip}</p>"}.join('<br />')
    plaintextbody = maybe_screwed.to_a.map{|name, text| "name\n---------\n#{text.strip}"}.join("\n\n")
  elsif !screwed.empty?
    subject = "Take the #{okay_line.slashify} train: #{screwed.keys.map(&:slashify).join(", ")} #{screwed.size > 1 ? 'are' : 'is'} fucked"
    body = screwed.to_a.map{|name, text| "#{name}\n---------\n#{text.to_s.strip}"}.join("\n\n")
    plaintextbody = screwed.to_a.map{|name, text| "name\n---------\n#{text.to_s.strip}"}.join("\n\n")
  else
    exit(1) #primary train works, \o/
  end
else
  if screwed.empty?
    subject = "All your lines may be screwed ¯\\_(ツ)_/¯"
    body = maybe_screwed.to_a.map{|name, text| "<h1>#{name}</h1><p>#{text.strip}</p>"}.join('<br />')
    plaintextbody = maybe_screwed.to_a.map{|name, text| "#{name}\n---------\n#{text.strip}"}.join("\n\n")
  elsif maybe_screwed.empty?
    subject = "All your lines are screwed :("
    body = screwed.to_a.map{|name, text| "#{name}\n---------\#{text.strip}"}.join("\n\n")
    plaintextbody = maybe_screwed.to_a.map{|name, text| "#{name}\n---------\n#{text.strip}"}.join("\n\n")
  else
    subject = maybe_screwed.keys.map(&:slashify).join(", ") + " may be screwed; #{screwed.map(&:slashify).join(", ")} #{screwed.size > 1 ? 'are' : 'is'} fucked"
    body = maybe_screwed.to_a.map{|name, text| "<h1>#{name}</h1><p>#{text.strip}</p>"}.join('<br />')
    plaintextbody = maybe_screwed.to_a.map{|name, text| "#{name}\n---------\n#{text.strip}"}.join("\n\n")
  end
end

htmlbody = <<-eos
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
 <head>
  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
  <title>Demystifying Email Design</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
</head>
<body>
<table align="center" border="0" cellpadding="0" cellspacing="0" width="600" style="border-collapse: collapse;">
 <tr>
  <td>
eos
htmlbody += body.to_s
htmlbody += <<-eos
  </td>
 </tr>
</table>
</body>
</html>
eos

if config['sns'] && config['sns']['secret_access_key'] && config['sns']['arn']&& config['sns']['access_key_id']
  AWS.config(access_key_id: config['sns']['access_key_id'], secret_access_key: config['sns']['secret_access_key'])
  sns = AWS::SNS::Topic.new(config['sns']['arn'])
  sns.publish( plaintextbody, :subject => subject ) unless ENV['NOMAIL']
else
  Mail.defaults do
    delivery_method :smtp, { 
      :address => config['email']['address'],
      :port => config['email']['port'],
      :user_name => config['email']['username'],
      :password => config['email']['password'],
      :authentication => :plain,
      :tls => true,
      # :openssl_verify_mode => OpenSSL::SSL::VERIFY_NONE, 
    }
  end

  # $stdout.puts subject + (body.nil? ? '' : ("|" + htmlbody))
  Mail.deliver do
    from     config['email']['from']
    to       config['email']['to']
    subject  subject

    text_part do
      body plaintextbody
    end

    html_part do
      content_type 'text/html; charset=UTF-8'
      body htmlbody
    end
  end unless ENV['NOMAIL']
end

CSV.open(statuses_csv, 'wb'){|csv| statuses.each{|status| csv << status } }

exit(0)

# output possibilities

# if primary train ok, send nothing
# if primary train 'delays'
#   consider secondary train as primary
#   append to subject "primary train delayed"
# if primary train 'planned work' or 'service change'


# (nothing)
# "Take 2/3: Q train fucked"
# "Take C train: Q, 2/3 fucked"
# "Q train may be screwed, 2 okay" (include text)
# "All your lines are screwed :("
# "Q, 2/3 may be screwed: C is definitely fucked"

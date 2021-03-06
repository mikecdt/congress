require 'nokogiri'

class VotesHouse

  # Syncs vote data with the House of Representatives.
  #
  # By default, looks through the Clerk's EVS pages, and
  # re/downloads data for the last 10 roll call votes.
  #
  # Options can be passed in to archive whole years, which can ignore
  # already downloaded files (to support resuming).
  #
  # options:
  #   force: if archiving, force it to re-download existing files.
  #   year: archive an entire year of data. 'current' for current year (defaults to latest 20)
  #   number: only download a specific roll call vote number for the given year. Ignores other options, except for year.
  #   limit: only download a certain number of votes (stop short, useful for testing/development)
  #   skip_text: don't search index related text

  def self.run(options = {})
    year = if options[:year].nil? or (options[:year] == 'current')
      Utils.current_legislative_year
    else
      options[:year].to_i
    end

    initialize_disk! year

    to_get = []

    if options[:number]
      to_get = [options[:number].to_i]
    else

      # count down from the top
      unless latest_roll = latest_roll_for(year, options)
        Report.failure self, "Failed to find the latest new roll on the clerk's page, can't go on."
        return
      end

      # no rolls yet for the year
      if latest_roll == 0
        Report.note self, "Okay, no roll call votes yet for #{year}."
        return
      end


      if options[:year] # year implies archive
        from_roll = 1
      else
        latest = options[:latest] ? options[:latest].to_i : 20
        from_roll = (latest_roll - latest) + 1
        from_roll = 1 if from_roll < 1
      end

      to_get = (from_roll..latest_roll).to_a.reverse

      if options[:limit]
        to_get = to_get.first options[:limit].to_i
      end
    end

    count = 0

    download_failures = []
    missing_bioguide_ids = []
    missing_bill_ids = []
    # missing_amendment_ids = []

    legislators = {}
    Legislator.only(Legislator.basic_fields).all.each do |legislator|
      legislators[legislator.bioguide_id] = Utils.legislator_for legislator
    end

    to_get.each do |number|
      roll_id = "h#{number}-#{year}"

      puts "[#{roll_id}] Syncing to disc..." if options[:debug]
      unless download_roll year, number, download_failures, options
        puts "[#{roll_id}] WARNING: Couldn't sync to disc, skipping"
        next
      end

      doc = Nokogiri::XML open(destination_for(year, number))

      puts "[#{roll_id}] Saving vote information..." if options[:debug]

      # 404s for missing votes return an HTML doc that won't make sense
      # example of this: there was no roll 484 in 2011 for a while, due to procedural foulup
      unless doc.at(:congress)
        puts "\tNot a valid XML vote, skipping" if options[:debug]
        next
      end

      congress = doc.at(:congress).inner_text.to_i

      bill_type, bill_number = bill_code_for doc
      bill_id = (bill_type and bill_number) ? "#{bill_type}#{bill_number}-#{congress}" : nil
      # amendment_id = amendment_id_for doc, bill_id

      voter_ids, voters = votes_for doc, legislators, missing_bioguide_ids
      roll_type = doc.at("vote-question").inner_text
      question = question_for doc, roll_type, bill_type, bill_number

      if vacated = vacated_for(doc)
        puts "[#{roll_id}] VACATED vote detected"
        next
      end

      vote = Vote.find_or_initialize_by roll_id: roll_id
      vote.attributes = {
        vote_type: Utils.vote_type_for(roll_type, roll_type),
        chamber: "house",
        year: year,
        number: number,

        congress: congress,

        roll_type: roll_type,
        question: question,
        result: doc.at("vote-result").inner_text,
        required: required_for(doc),

        voted_at: voted_at_for(doc),
        voter_ids: voter_ids,
        voters: voters,

        breakdown: Utils.vote_breakdown_for(voters),

        source: url_for(year, number),
        url: url_for(year, number)
      }

      if bill_id
        vote[:bill_id] = bill_id
        if bill = Utils.bill_for(bill_id)
          vote[:bill] = bill
        else
          missing_bill_ids << {roll_id: roll_id, bill_id: bill_id}
        end
      end

      # if amendment_id
      #   if amendment = Amendment.where(:amendment_id => amendment_id).only(Amendment.basic_fields).first
      #     vote.attributes = {
      #       :amendment_id => amendment_id,
      #       :amendment => Utils.amendment_for(amendment)
      #     }
      #   else
      #     missing_amendment_ids << {:roll_id => roll_id, :amendment_id => amendment_id}
      #   end
      # end

      vote.save!

      count += 1
    end

    if download_failures.any?
      Report.warning self, "Failed to download #{download_failures.size} files while syncing against the House Clerk votes collection for #{year}", download_failures: download_failures
    end

    if missing_bioguide_ids.any?
      missing_bioguide_ids = missing_bioguide_ids.uniq
      Report.warning self, "Found #{missing_bioguide_ids.size} missing Bioguide IDs. Vote counts on roll calls may be inaccurate until these are fixed.", {missing_bioguide_ids: missing_bioguide_ids}
    end

    if missing_bill_ids.any?
      Report.note self, "Found #{missing_bill_ids.size} missing bill_id's while processing votes.", {missing_bill_ids: missing_bill_ids}
    end

    # if missing_amendment_ids.any?
    #   Report.warning self, "Found #{missing_amendment_ids.size} missing amendment_id's while processing votes.", {missing_amendment_ids: missing_amendment_ids}
    # end

    Report.success self, "Successfully synced #{count} House roll call votes for #{year}"
  end


  def self.initialize_disk!(year)
    FileUtils.mkdir_p "data/house/rolls/#{year}"
  end

  def self.url_for(year, number)
    "http://clerk.house.gov/evs/#{year}/roll#{zero_prefix number}.xml"
  end

  def self.destination_for(year, number)
    "data/house/rolls/#{year}/#{zero_prefix number}.xml"
  end

  def self.zero_prefix(number)
    if number < 10
      "00#{number}"
    elsif number < 100
      "0#{number}"
    else
      number
    end
  end

  def self.download_roll(year, number, failures, options = {})
    url = url_for year, number
    destination = destination_for year, number

    # cache aggressively, redownload only if force option is passed
    if File.exists?(destination) and options[:force].blank?
      puts "\tCached at #{destination}" if options[:debug]
      return true
    end

    puts "\tDownloading #{url} to #{destination}" if options[:debug]

    unless curl = Utils.curl(url, destination)
      failures << {message: "Couldn't download", url: url, destination: destination}
      return false
    end

    # 404s come back as 200's, and are HTML documents
    unless curl.content_type == "text/xml"
      failures << {message: "Probably 404", url: url, destination: destination, content_type: curl.content_type}
      FileUtils.rm destination
      return false
    end

    # sanity check on files less than expected -
    # most are ~82K, so if something is less than 80K, check the XML for malformed errors
    if curl.downloaded_content_length < 80000
      # retry once, quick check
      puts "\tRe-downloading once, looked truncated" if options[:debug]
      curl = Utils.curl(url, destination)

      if curl.downloaded_content_length < 80000
        begin
          Nokogiri::XML(open(destination)) {|config| config.strict}
        rescue
          puts "\tFailed strict XML check, assuming it's still truncated" if options[:debug]
          failures << {message: "Failed check", url: url, destination: destination, content_length: curl.downloaded_content_length}
          FileUtils.rm destination
          return false
        else
          puts "\tOK, passes strict XML check, accepting it" if options[:debug]
        end
      end
    end

    true
  end

  # latest roll number on the House Clerk's listing of latest votes
  def self.latest_roll_for(year, options = {})
    url = "http://clerk.house.gov/evs/#{year}/index.asp"

    puts "[#{year}] Fetching index page for year from House Clerk..." if options[:debug]
    return nil unless body = Utils.curl(url)
    return nil unless doc = Nokogiri::HTML(body)

    return 0 if body =~ /No roll call votes have been posted yet./i

    element = doc.css("tr td a").first
    return nil unless element and element.text.present?
    number = element.text.to_i
    number > 0 ? number : nil
  end

  def self.vacated_for(doc)
    doc.at("action-time").inner_text.blank? and !!(doc.at("vote-desc").inner_text =~ /vacated/)
  end

  def self.required_for(doc)
    if doc.at("vote-type").inner_text =~ /^2\/3/i
      "2/3"
    else
      "1/2"
    end
  end

  def self.vote_mapping
    {
      "Aye" => "Yea",
      "No" => "Nay"
    }
  end

  def self.votes_for(doc, legislators, missing_ids)
    voter_ids = {}
    voters = {}

    doc.search("//vote-data/recorded-vote").each do |elem|
      vote = (elem / 'vote').text
      vote = vote_mapping[vote] || vote # check to see if it should be standardized

      bioguide_id = (elem / 'legislator').first['name-id']

      if legislators[bioguide_id]
        voter = legislators[bioguide_id]
        bioguide_id = voter['bioguide_id']
        voter_ids[bioguide_id] = vote
        voters[bioguide_id] = {:vote => vote, :voter => voter}
      else
        number = doc.at("rollcall-num").text
        missing_ids << [bioguide_id, number]
      end
    end

    [voter_ids, voters]
  end

  def self.create_bill(bill_id, doc)
    bill = Utils.bill_from bill_id
    bill.save!
    bill
  end

  # returns bill type and number
  def self.bill_code_for(doc)
    elem = doc.at 'legis-num'
    if elem
      code = elem.text.strip.gsub(' ', '').downcase
      type = code.gsub /\d/, ''
      number = code.gsub type, ''

      if !["hr", "hres", "hjres", "hconres", "s", "sres", "sjres", "sconres"].include?(type)
        return nil, nil
      else
        return type, number
      end
    else
      nil
    end
  end

  def self.zero_prefix(number)
    if number < 10
      "00#{number}"
    elsif number < 100
      "0#{number}"
    else
      number
    end
  end

  def self.voted_at_for(doc)
    datestamp = doc.at("action-date").inner_text
    timestamp = doc.at("action-time").inner_text
    Utils.utc_parse "#{datestamp} #{timestamp}"
  end

  def self.question_for(doc, roll_type, bill_type, bill_number)
    question = roll_type.dup
    desc = doc.at("vote-desc").inner_text

    if bill_type and bill_number
      question << " -- " + Utils.format_bill_code(bill_type, bill_number)
    end

    if desc.present?
      question << " -- " + desc
    end

    question
  end
end
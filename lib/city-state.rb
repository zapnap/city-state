require "city-state/version"
require "yaml"

module CS
  # CS constants
  MAXMIND_ZIPPED_URL = "http://geolite.maxmind.com/download/geoip/database/GeoLite2-City-CSV.zip"
  FILES_FOLDER = File.expand_path('../db', __FILE__)
  MAXMIND_DB_FN = File.join(FILES_FOLDER, "GeoLite2-City-Locations-en.csv")
  COUNTRIES_FN = File.join(FILES_FOLDER, "countries.yml")

  @countries, @states, @cities = [{}, {}, {}]

  def self.update_maxmind
    require "open-uri"
    require "zip"

    # get zipped file
    f_zipped = open(MAXMIND_ZIPPED_URL)

    # unzip file:
    # recursively searches for "GeoLite2-City-Locations-en"
    Zip::File.open(f_zipped) do |zip_file|
      zip_file.each do |entry|
        if entry.name["GeoLite2-City-Locations-en"].present?
          fn = entry.name.split("/").last
          entry.extract(File.join(FILES_FOLDER, fn)) { true } # { true } is to overwrite
          break
        end
      end
    end
    true
  end

  def self.update
    self.update_maxmind # update via internet
    Dir[File.join(FILES_FOLDER, "states.*")].each do |state_fn|
      self.install(state_fn.split(".").last.upcase.to_sym) # reinstall country
    end
    @countries, @states, @cities = [{}, {}, {}] # invalidades cache
    File.delete COUNTRIES_FN # force countries.yml to be generated at next call of CS.countries
    true
  end

  # constants: CVS position
  ID = 0
  COUNTRY = 4
  COUNTRY_LONG = 5
  STATE = 6
  STATE_LONG = 7
  CITY = 10

  def self.install(country)
    # get CSV if doesn't exists
    update_maxmind unless File.exists? MAXMIND_DB_FN

    # normalize "country"
    country = country.to_s.upcase

    # some state codes are empty: we'll use "states-replace" in these cases
    states_replace_fn = File.join(FILES_FOLDER, "states-replace.yml")
    states_replace = symbolize(YAML::load_file(states_replace_fn))
    states_replace = states_replace[country.to_sym] || {} # we need just this country
    states_replace_inv = states_replace.invert # invert key with value, to ease the search

    # read CSV line by line
    cities = {}
    states = {}
    File.foreach(MAXMIND_DB_FN) do |line|
      rec = line.split(",")
      next if rec[COUNTRY] != country
      next if (blank(rec[STATE]) && blank(rec[STATE_LONG])) || blank(rec[CITY])

      # some state codes are empty: we'll use "states-replace" in these cases
      rec[STATE] = states_replace_inv[rec[STATE_LONG]] if blank(rec[STATE])
      rec[STATE] = rec[STATE_LONG] if blank(rec[STATE]) # there's no correspondent in states-replace: we'll use the long name as code

      # some long names are empty: we'll use "states-replace" to get the code
      rec[STATE_LONG] = states_replace[rec[STATE]] if blank(rec[STATE_LONG])

      # normalize
      rec[STATE] = rec[STATE].to_sym
      rec[CITY].gsub!(/\"/, "") # sometimes names come with a "\" char
      rec[STATE_LONG].gsub!(/\"/, "") # sometimes names come with a "\" char

      # cities list: {TX: ["Texas City", "Another", "Another 2"]}
      cities.merge!({rec[STATE] => []}) if ! states.has_key?(rec[STATE])
      cities[rec[STATE]] << rec[CITY]

      # states list: {TX: "Texas", CA: "California"}
      if ! states.has_key?(rec[STATE])
        state = {rec[STATE] => rec[STATE_LONG]}
        states.merge!(state)
      end
    end

    # sort
    cities = Hash[cities.sort]
    states = Hash[states.sort]
    cities.each { |k, v| cities[k].sort! }

    # save to states.us and cities.us
    states_fn = File.join(FILES_FOLDER, "states.#{country.downcase}")
    cities_fn = File.join(FILES_FOLDER, "cities.#{country.downcase}")
    File.open(states_fn, "w") { |f| f.write states.to_yaml }
    File.open(cities_fn, "w") { |f| f.write cities.to_yaml }
    File.chmod(0666, states_fn, cities_fn) # force permissions to rw_rw_rw_ (issue #3)
    true
  end

  def self.cities(country, state = nil)
    country = normalized(country)

    # load the country file
    if @cities[country].nil?
      cities_fn = File.join(FILES_FOLDER, "cities.#{country.to_s.downcase}")
      self.install(country) if ! File.exists? cities_fn
      @cities[country] = symbolize(YAML::load_file(cities_fn))
    end

    if state
      @cities[country][normalized(state)] || []
    else
      @cities[country].map { |k,v| v }.flatten
    end
  end

  def self.states(country)
    country = normalized(country)

    # load the country file
    if @states[country].nil?
      states_fn = File.join(FILES_FOLDER, "states.#{country.to_s.downcase}")
      self.install(country) if ! File.exists? states_fn
      @states[country] = symbolize(YAML::load_file(states_fn))
    end

    @states[country] || {}
  end

  # list of all countries of the world (countries.yml)
  def self.countries
    if ! File.exists? COUNTRIES_FN
      # countries.yml doesn't exists, extract from MAXMIND_DB
      update_maxmind unless File.exists? MAXMIND_DB_FN

      # reads CSV line by line
      File.foreach(MAXMIND_DB_FN) do |line|
        rec = line.split(",")
        next if blank(rec[COUNTRY]) || blank(rec[COUNTRY_LONG]) # jump empty records
        country = rec[COUNTRY].to_s.upcase.to_sym # normalize to something like :US, :BR
        if @countries[country].nil?
          long = rec[COUNTRY_LONG].gsub(/\"/, "") # sometimes names come with a "\" char
          @countries[country] = long
        end
      end

      # sort and save to "countries.yml"
      @countries = Hash[@countries.sort]
      File.open(COUNTRIES_FN, "w") { |f| f.write @countries.to_yaml }
      File.chmod(0666, COUNTRIES_FN) # force permissions to rw_rw_rw_ (issue #3)
    else
      # countries.yml exists, just read it
      @countries = symbolize(YAML::load_file(COUNTRIES_FN))
    end
    @countries
  end

  # get is a method to simplify the use of city-state
  # get = countries, get(country) = states(country), get(country, state) = cities(state, country)
  def self.get(country = nil, state = nil)
    return self.countries if country.nil?
    return self.states(country) if state.nil?
    return self.cities(country, state)
  end

  def self.normalized(str)
    if str && str != ''
      str.to_s.upcase.to_sym
    else
      nil
    end
  end

  def self.blank(value)
    value.nil? || value == ''
  end

  def self.symbolize(obj)
    return obj.reduce({}) do |memo, (k, v)|
      memo.tap { |m| m[k.to_sym] = symbolize(v) }
    end if obj.is_a? Hash

    return obj.reduce([]) do |memo, v| 
      memo << symbolize(v); memo
    end if obj.is_a? Array

    obj
  end
end

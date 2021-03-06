# Copyright (C) 2012-2016 Zammad Foundation, http://zammad-foundation.org/

class Calendar < ApplicationModel
  include ChecksClientNotification
  include CanUniqName

  store :business_hours
  store :public_holidays

  before_create  :validate_public_holidays, :fetch_ical
  before_update  :validate_public_holidays, :fetch_ical
  after_create   :sync_default, :min_one_check
  after_update   :sync_default, :min_one_check
  after_destroy  :min_one_check

=begin

set inital default calendar

  calendar = Calendar.init_setup

returns calendar object

=end

  def self.init_setup(ip = nil)

    # ignore client ip if not public ip
    if ip && ip =~ /^(::1|127\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.)/
      ip = nil
    end

    # prevent multible setups for same ip
    cache = Cache.get('Calendar.init_setup.done')
    return if cache && cache[:ip] == ip
    Cache.write('Calendar.init_setup.done', { ip: ip }, { expires_in: 1.hour })

    # call for calendar suggestion
    calendar_details = Service::GeoCalendar.location(ip)
    return if !calendar_details

    calendar_details['name'] = Calendar.generate_uniq_name(calendar_details['name'])
    calendar_details['default'] = true
    calendar_details['created_by_id'] = 1
    calendar_details['updated_by_id'] = 1

    # find if auto generated calendar exists
    calendar = Calendar.find_by(default: true, updated_by_id: 1, created_by_id: 1)
    if calendar
      calendar.update_attributes(calendar_details)
      return calendar
    end
    create(calendar_details)
  end

=begin

get default calendar

  calendar = Calendar.default

returns calendar object

=end

  def self.default
    find_by(default: true)
  end

=begin

returns preset of ical feeds

  feeds = Calendar.ical_feeds

returns

  {
    'http://www.google.com/calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics' => 'US',
    ...
  }

=end

  def self.ical_feeds
    data = YAML.load_file(Rails.root.join('config/holiday_calendars.yml'))
    url  = data['url']

    data['countries'].map do |country, domain|
      [(url % { domain: domain }), country]
    end.to_h
  end

=begin

get list of available timezones and UTC offsets

  list = Calendar.timezones

returns

  {
    'America/Los_Angeles' => -7
    ...
  }

=end

  def self.timezones
    list = {}
    TZInfo::Timezone.all_country_zone_identifiers.each { |timezone|
      t = TZInfo::Timezone.get(timezone)
      diff = t.current_period.utc_total_offset / 60 / 60
      list[ timezone ] = diff
    }
    list
  end

=begin

syn all calendars with ical feeds

  success = Calendar.sync

returns

  true # or false

=end

  def self.sync
    Calendar.find_each(&:sync)
    true
  end

=begin

syn one calendars with ical feed

  calendar = Calendar.find(4711)
  success = calendar.sync

returns

  true # or false

=end

  def sync(without_save = nil)
    return if !ical_url

    # only sync every 5 days
    cache_key = "CalendarIcal::#{id}"
    cache = Cache.get(cache_key)
    return if !last_log && cache && cache[:ical_url] == ical_url

    begin
      events = {}
      if ical_url && !ical_url.empty?
        events = Calendar.parse(ical_url)
      end

      # sync with public_holidays
      if !public_holidays
        self.public_holidays = {}
      end

      # remove old ical entries if feed has changed
      public_holidays.each { |day, meta|
        next if !public_holidays[day]['feed']
        next if meta['feed'] == Digest::MD5.hexdigest(ical_url)
        public_holidays.delete(day)
      }

      # sync new ical feed dates
      events.each { |day, summary|
        if !public_holidays[day]
          public_holidays[day] = {}
        end

        # ignore if already added or changed
        next if public_holidays[day].key?('active')

        # create new entry
        public_holidays[day] = {
          active: true,
          summary: summary,
          feed: Digest::MD5.hexdigest(ical_url)
        }
      }
      self.last_log = nil
      cache = Cache.write(
        cache_key,
        { public_holidays: public_holidays, ical_url: ical_url },
        { expires_in: 5.days },
      )
    rescue => e
      self.last_log = e.inspect
    end

    self.last_sync = Time.zone.now
    if !without_save
      save
    end
    true
  end

  def self.parse(location)
    if location =~ /^http/i
      result = UserAgent.get(location)
      if !result.success?
        raise result.error
      end
      cal_file = result.body
    else
      cal_file = File.open(location)
    end

    cals = Icalendar::Calendar.parse(cal_file)
    cal = cals.first
    events = {}
    cal.events.each { |event|
      next if event.dtstart < Time.zone.now - 1.year
      next if event.dtstart > Time.zone.now + 3.years
      day = "#{event.dtstart.year}-#{format('%02d', event.dtstart.month)}-#{format('%02d', event.dtstart.day)}"
      comment = event.summary || event.description
      comment = Encode.conv( 'utf8', comment.to_s.force_encoding('utf-8') )
      if !comment.valid_encoding?
        comment = comment.encode('utf-8', 'binary', invalid: :replace, undef: :replace, replace: '?')
      end

      # ignore daylight saving time entries
      next if comment =~ /(daylight saving|sommerzeit|summertime)/i
      events[day] = comment
    }
    events.sort.to_h
  end

  private

  # if changed calendar is default, set all others default to false
  def sync_default
    return true if !default
    Calendar.find_each { |calendar|
      next if calendar.id == id
      next if !calendar.default
      calendar.default = false
      calendar.save
    }
    true
  end

  # check if min one is set to default true
  def min_one_check
    if !Calendar.find_by(default: true)
      first = Calendar.order(:created_at, :id).limit(1).first
      first.default = true
      first.save
    end

    # check if sla's are refer to an existing calendar
    default_calendar = Calendar.find_by(default: true)
    Sla.find_each { |sla|
      if !sla.calendar_id
        sla.calendar_id = default_calendar.id
        sla.save!
        next
      end
      if !Calendar.find_by(id: sla.calendar_id)
        sla.calendar_id = default_calendar.id
        sla.save!
      end
    }
    true
  end

  # fetch ical feed
  def fetch_ical
    sync(true)
    true
  end

  # validate format of public holidays
  def validate_public_holidays

    # fillup feed info
    before = public_holidays_was
    public_holidays.each { |day, meta|
      if before && before[day] && before[day]['feed']
        meta['feed'] = before[day]['feed']
      end
      meta['active'] = if meta['active']
                         true
                       else
                         false
                       end
    }
    true
  end
end

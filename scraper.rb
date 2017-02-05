require 'scraperwiki'
require 'mechanize'
require 'filesize'

$agent = Mechanize.new
$site_url = "http://toloka.to"
$login_url = "http://toloka.to/login.php?redirect=index.php"
$recent_registered = nil

def parse_user(id, data={}, stats={})
    $agent.get("#{$site_url}/u#{id}")
    username_re = /:: (.+)$/.match($agent.page.search('.forumline th').first.text)
    return unless username_re
    data[:id] = id
    data[:username] = username_re[1]
    user_picture = $agent.page.search('.postdetails img').last
    src_re = /avatars/.match(user_picture['src'])
    user_info = $agent.page.search('.forumline table')[0]
    data[:picture] = user_picture && src_re ? $agent.resolve(user_picture['src']).to_s : nil
    user_info.search('td').each do |td|
       if td.text.include? "З нами з:"
           data[:joined] = parse_date(td.next.next.text)
       end
       if td.text.include? "Востаннє:"
           data[:last_seen] = parse_date(td.next.next.text)
       end
    end
    # data[:joined] = parse_date(user_info.search('td')[1].text)
    # data[:last_seen] = parse_date(user_info.search('td')[3].text)
    $recent_registered = true if data[:joined] > Date.today - 30
    return if data[:joined] === data[:last_seen]
    return if data[:last_seen].nil? || data[:last_seen] < Date.today - 180
    user_stats = $agent.page.search('.forumline table').last
    if user_stats
        stats[:user_id] = id
        stats[:date] = Date.today
        stats[:uploaded] = 0
        stats[:downloaded] = 0
        has_stats = parse_stats(user_stats, stats)
        return unless has_stats
        p "[debug] user #{id} has stats"
    else
        p "[debug] user #{id} hide stats"
        return
    end
    ScraperWiki::save_sqlite([:id], data, 'users')
    sleep 1
    data
end

def parse_stats(stats_node, stats={})
    upload_node = stats_node.search('tr')[1]
    download_node = stats_node.search('tr')[2]
    ratio_node = stats_node.search('tr')[4]
    releases_node = stats_node.search('tr')[6]
    thanks_node = stats_node.search('tr')[7]
    tomorrow_stats = stats.clone
    tomorrow_stats[:date] -= 1
    tomorrow_stats[:uploaded] += Filesize.from(upload_node.search('td')[3].text).to_i
    tomorrow_stats[:downloaded] += Filesize.from(download_node.search('td')[3].text).to_i
    stats[:uploaded_all] = Filesize.from(upload_node.search('td')[1].text).to_i
    stats[:downloaded_all] = Filesize.from(download_node.search('td')[1].text).to_i
    return nil unless stats[:uploaded_all]
    return nil unless stats[:downloaded_all] < Filesize.from('2 GB')
    ration_re = /: ([\d\.]+)/.match(ratio_node.search('td')[1].text)
    stats[:ratio] = ration_re ? ration_re[1].to_f : 0.0
    stats[:releases] = releases_node.search('td')[1].text.to_i
    if thanks_node.search('td')[0].text === "Подякували:"
        stats[:thanks] = thanks_node.search('td')[1].text.to_i
    else
        stats[:thanks] = 0
    end
    ScraperWiki::save_sqlite([:user_id, :date], stats, 'stats')
    ScraperWiki::save_sqlite([:user_id, :date], tomorrow_stats, 'stats')
    return stats
end

def fetch_last_user_id()
    link = $agent.get("#{$site_url}/memberlist.php").search('form .forumline td')[3].search('a').first
    if link
        ScraperWiki::save_var('max_user', /u(\d+)/.match(link['href'])[1].to_i)
    end
end

def login(force=false)
    if not force and File.exist?('cookies.yaml')
        p "[debug] load cookies"
        $agent.cookie_jar.load('cookies.yaml')
        $agent.get($site_url)
    else
        p "[debug] auth on site"
        $agent.get($login_url, referer: $site_url).form_with(action: 'login.php') do |f|
            f['username'] = ENV['TOLOKA_USER']
            f['password'] = ENV['TOLOKA_PASSWORD']
            f.click_button(f.button_with(name: 'login'))
        end
    end
end

def parse_date(str)
    begin
        return Date.strptime(str, '%d.%m.%y')
    rescue
        nil
    end
end

login()

fetch_last_user_id()

$start_num = ScraperWiki::get_var('last_user') || 1
$end_num = ScraperWiki::get_var('max_user') || 860000

begin 
    begin
        parse_user($start_num)
        ScraperWiki::save_var('last_user', $start_num)
    rescue
        p "failed to parse user #{$start_num}"
    end
    $start_num += 1
end while $recent_registered.nil? && $start_num < $end_num

$current_user = ScraperWiki.select('MIN(id) as id FROM users').first

begin
    begin
        parse_user($current_user['id'])
    rescue
        p "failed update stats for user #{$current_user['id']}"
    end
end while $current_user = ScraperWiki.select('id FROM users WHERE id > ? ORDER BY id ASC', [$current_user['id']]).first

$agent.cookie_jar.save('cookies.yaml', session: true)

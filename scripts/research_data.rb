require 'csv'
require 'date'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tempfile'
require 'time'
require 'uri'

ROOT = File.expand_path('..', __dir__)
SCHEMAS = {
  'data/sources.csv' => %w[source_id aliases title publisher source_type url document_path published_on retrieved_on applicable_region applicable_year verification_status verified_scope limitations archive_format],
  'private/profile.csv' => %w[record_id recorded_on subject attribute value value_status source_id notes],
  'data/admissions.csv' => %w[record_id recorded_on admission_year province candidate_category batch plan_type institution_code institution_name campus group_code group_members major_code major_name subject_requirements plan_count score rank statistic_type value_origin verification_status source_ids notes],
  'data/programmes.csv' => %w[record_id recorded_on record_kind institution major_name curriculum_overview possible_directions training_and_risks evidence_status evidence_scope source_ids notes],
  'data/pathways.csv' => %w[record_id recorded_on record_kind policy_year province institution channel item details start_date end_date date_precision action_status verification_status source_ids notes],
  'data/decisions.csv' => %w[record_id recorded_on record_kind topic decision rationale family_confirmation source_ids notes]
}.freeze

def load_tables
  SCHEMAS.each_with_object({}) do |(relative, expected), tables|
    rows = CSV.read(File.join(ROOT, relative), encoding: 'bom|utf-8')
    raise "#{relative}: header mismatch" unless rows.shift == expected
    raise "#{relative}: wrong column count" unless rows.all? { |row| row.length == expected.length }
    tables[relative] = rows.map { |row| expected.zip(row).to_h }
  end
end

def local_path(relative)
  path = File.expand_path(relative, ROOT)
  raise "Path outside workspace: #{relative}" unless path.start_with?(ROOT + File::SEPARATOR)
  path
end

def archive_entries
  path = File.join(ROOT, 'raw', 'manifest.jsonl')
  return [] unless File.exist?(path)
  File.readlines(path).reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
end

def check_subject_imports(sources)
  manifest = File.join(ROOT, 'data/derived/manifest.jsonl')
  return unless File.exist?(manifest)
  imports = File.readlines(manifest).reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
  imports.each do |entry|
    raise 'Derived data has unknown source' unless sources.include?(entry.fetch('source_id'))
    origin = archive_entries.find { |item| item['path'] == entry.fetch('source_path') && item['source_id'] == entry['source_id'] }
    raise 'Derived source archive mismatch' unless origin && origin['sha256'] == entry.fetch('source_sha256')
    files = entry.fetch('files')
    raise 'Incomplete derived file list' unless files.map { |item| File.basename(item.fetch('path')) }.sort == %w[all.csv eligible.csv institutions.csv summary.json]
    files.each do |item|
      path = local_path(item.fetch('path'))
      raise "Derived file missing or changed: #{item['path']}" unless File.file?(path) && Digest::SHA256.file(path).hexdigest == item.fetch('sha256')
    end
    all_path = local_path(files.find { |item| item['path'].end_with?('/all.csv') }.fetch('path'))
    all_rows = {}
    counts = Hash.new(0)
    CSV.foreach(all_path, headers: true) do |row|
      identifier = row.fetch('record_id')
      raise 'Duplicate derived row ID' if all_rows.key?(identifier)
      raise 'Derived row source mismatch' unless row['source_id'] == entry['source_id'] && row['selected_subjects'] == entry.fetch('selected_subjects').join('|')
      status = row.fetch('eligibility_status')
      raise 'Invalid derived status' unless %w[eligible ineligible review_required].include?(status)
      all_rows[identifier] = row.fields
      counts[status] += 1
    end
    raise 'Derived total count mismatch' unless all_rows.length == entry.fetch('total_records')
    %w[eligible ineligible review_required].each do |status|
      raise 'Derived status count mismatch' unless counts[status] == entry.fetch("#{status}_records")
    end
    eligible_path = local_path(files.find { |item| item['path'].end_with?('/eligible.csv') }.fetch('path'))
    eligible_ids = []
    CSV.foreach(eligible_path, headers: true) do |row|
      identifier = row.fetch('record_id')
      raise 'Eligible subset mismatch' unless row['eligibility_status'] == 'eligible' && row.fields == all_rows[identifier]
      eligible_ids << identifier
    end
    raise 'Eligible subset count or uniqueness mismatch' unless eligible_ids.length == counts['eligible'] && eligible_ids.uniq.length == eligible_ids.length
    Time.iso8601(entry.fetch('generated_at'))
  end
  puts "Subject imports: #{imports.length} provenance, hashes and subset checks OK"
end

def check
  tables = load_tables
  sources = tables.fetch('data/sources.csv').map { |row| row.fetch('source_id') }
  tables.each do |relative, rows|
    key = SCHEMAS.fetch(relative).first
    identifiers = rows.map { |row| row.fetch(key) }
    raise "#{relative}: blank or duplicate ID" if identifiers.any? { |value| value.to_s.empty? } || identifiers.uniq.length != identifiers.length
    rows.each do |row|
      unless relative == 'data/sources.csv'
        reference = row['source_ids'] || row['source_id']
        raise "#{relative}: missing source" if reference.to_s.empty?
      end
      row.each do |field, value|
        next if value.to_s.empty?
        raise "#{relative}: spreadsheet formula in #{field}" if value.match?(/\A[=+@-]/)
        Date.iso8601(value) if field.end_with?('_on') || %w[start_date end_date].include?(field)
        raise "#{relative}: invalid year" if %w[admission_year policy_year applicable_year].include?(field) && !value.match?(/\A\d{4}\z/)
        if %w[source_id source_ids].include?(field) && relative != 'data/sources.csv'
          raise "#{relative}: unknown source" unless (value.split('|') - sources).empty?
        end
      end
      if relative == 'data/sources.csv'
        if row['url']
          address = URI.parse(row['url'])
          raise "#{relative}: invalid URL" unless %w[http https].include?(address.scheme) && address.host
        end
        raise "#{relative}: missing document" if row['document_path'] && !File.file?(local_path(row['document_path']))
        raise "#{relative}: invalid archive format" if row['archive_format'] && !%w[html xlsx pdf js zip xls].include?(row['archive_format'])
      end
      if relative == 'data/pathways.csv'
        raise "#{relative}: invalid action status" unless %w[historical_reference reference_only todo paused done].include?(row['action_status'])
        if row['start_date'] && row['end_date']
          raise "#{relative}: inverted dates" if row['start_date'] > row['end_date']
        end
        raise "#{relative}: expired date marked todo" if row['action_status'] == 'todo' && row['end_date'] && Date.iso8601(row['end_date']) < Date.today
      end
      if relative == 'data/admissions.csv'
        required = %w[admission_year province institution_name statistic_type value_origin verification_status source_ids]
        raise "#{relative}: missing admission context" unless required.all? { |field| !row[field].to_s.empty? }
        %w[plan_count score rank].each do |field|
          next unless row[field]
          raise "#{relative}: invalid #{field}" unless row[field].match?(/\A\d+(?:\.\d+)?\z/)
        end
      end
    end
    puts "#{relative}: #{rows.length} records OK"
  end
  archives = archive_entries
  archives.each do |entry|
    raise 'Archive has unknown source' unless sources.include?(entry.fetch('source_id'))
    path = local_path(entry.fetch('path'))
    raise "Archive missing or changed: #{entry['path']}" unless File.file?(path) && Digest::SHA256.file(path).hexdigest == entry.fetch('sha256')
    Time.iso8601(entry.fetch('retrieved_at'))
  end
  puts "Archives: #{archives.length} SHA-256 checks OK"
  check_subject_imports(sources)
  tables
end

def archive(source_ids)
  raise 'Specify one or more source IDs' if source_ids.empty?
  sources = check.fetch('data/sources.csv')
  FileUtils.mkdir_p(File.join(ROOT, 'raw'))
  source_ids.each do |source_id|
    source = sources.find { |row| row['source_id'] == source_id }
    raise "Unknown source: #{source_id}" unless source
    extension = source['archive_format']
    raise "Not a downloadable source: #{source_id}" unless source['url'] && %w[html xlsx pdf js zip xls].include?(extension)
    Tempfile.create(['download-', '.tmp'], File.join(ROOT, 'raw')) do |temporary|
      response, error, result = Open3.capture3('curl', '--fail', '--location', '--silent', '--show-error', '--max-time', '60', '--output', temporary.path, '--write-out', '%{http_code}\t%{content_type}\t%{url_effective}', source['url'])
      raise "Download failed for #{source_id}: #{error}" unless result.success?
      http_code, content_type, effective_url = response.split("\t", 3)
      raise "Empty download: #{source_id}" if File.zero?(temporary.path)
      if extension == 'xlsx'
        contents, zip_error, zip_result = Open3.capture3('unzip', '-Z1', temporary.path)
        raise "Invalid XLSX: #{zip_error}" unless zip_result.success? && contents.lines.map(&:strip).include?('xl/workbook.xml')
      elsif extension == 'pdf'
        raise "Not a PDF response: #{source_id}" unless File.binread(temporary.path, 1024).include?('%PDF-')
      elsif extension == 'xls'
        raise "Not an OLE Excel response: #{source_id}" unless File.binread(temporary.path, 8) == "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b
      elsif extension == 'zip'
        _, zip_error, zip_result = Open3.capture3('unzip', '-tqq', temporary.path)
        raise "Invalid ZIP: #{zip_error}" unless zip_result.success?
      elsif extension == 'js'
        contents = File.read(temporary.path, encoding: 'UTF-8')
        raise "Not the public admission data script: #{source_id}" unless %w[columnList filterList dataList].all? { |name| contents.match?(/var\s+#{name}\s*=/) }
      else
        sample = File.binread(temporary.path, 8192).force_encoding('UTF-8').scrub
        raise "Not an HTML response: #{source_id}" unless sample.match?(/<html|<!doctype\s+html/i)
      end
      stamp = Time.now.utc
      relative = "raw/#{source_id}/#{stamp.strftime('%Y%m%dT%H%M%SZ')}-#{Process.pid}.#{extension}"
      destination = local_path(relative)
      raise "Refusing to overwrite: #{relative}" if File.exist?(destination)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.mv(temporary.path, destination)
      entry = {
        source_id: source_id, requested_url: source['url'], effective_url: effective_url,
        retrieved_at: stamp.iso8601, http_status: http_code, content_type: content_type,
        path: relative, bytes: File.size(destination), sha256: Digest::SHA256.file(destination).hexdigest,
        capture_scope: 'http_response_not_rendered', verification_note: 'Archive is not content verification; source status unchanged.'
      }
      File.open(File.join(ROOT, 'raw', 'manifest.jsonl'), 'a') { |manifest| manifest.puts(JSON.generate(entry)) }
      puts "Archived #{source_id}: #{entry[:bytes]} bytes"
    end
  end
  check
end

def backup
  check
  FileUtils.mkdir_p(File.join(ROOT, 'backups'))
  relative = "backups/research-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{Process.pid}.tar.gz"
  entries = %w[.gitignore Gemfile Gemfile.lock README.md AGENTS.md PLAN.md STATUS.md RESEARCH.md MAJORS_AND_PATHWAYS.md SUBJECT_REQUIREMENTS.md data private raw scripts].select { |entry| File.exist?(File.join(ROOT, entry)) }
  success = system('tar', '--exclude=*/node_modules', '-czf', local_path(relative), '-C', ROOT, *entries)
  raise 'Backup failed' unless success
  puts "Local unencrypted backup: #{relative}"
  puts "SHA-256: #{Digest::SHA256.file(local_path(relative)).hexdigest}"
end

if $PROGRAM_NAME == __FILE__
  begin
    command = ARGV.shift || 'check'
    case command
    when 'check' then check
    when 'archive' then archive(ARGV)
    when 'backup' then backup
    else raise 'Usage: ruby scripts/research_data.rb check | archive SOURCE_ID... | backup'
    end
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
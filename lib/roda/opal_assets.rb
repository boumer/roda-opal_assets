require "yaml"
require "roda/opal_assets/version"
require "roda"
require "opal"
require "uglifier" if ENV['RACK_ENV'] == 'production'

class Roda
  class OpalAssets
    def initialize env: ENV.fetch('RACK_ENV') { 'development' }
      @env = env.to_sym
      @assets = []
      @file_cache = {}

      sprockets

      source_maps
    end

    def route r
      unless production?
        r.on source_map_prefix[1..-1] do
          r.run source_maps
        end
        r.on 'assets/js' do
          r.run sprockets
        end
        r.on 'assets/css' do
          r.run sprockets
        end
      end
    end

    def js file
      file << '.js' unless file.end_with? '.js'
      scripts = ''

      if production?
        scripts << %{<script src="/assets/#{manifest[file]}"></script>\n}
      else
        asset = sprockets[file]

        asset.to_a.each { |dependency|
          scripts << %{<script src="/assets/js/#{dependency.digest_path}?body=1"></script>\n}
        }

        scripts << %{<script>#{opal_boot_code file}</script>}
      end

      scripts
    end

    def stylesheet file, media: :all
      file << '.css' unless file.end_with? '.css'
      asset = sprockets[file]

      if asset.nil?
        raise "File not found: #{file}.css"
      end

      path = asset.filename.to_s.sub(Dir.pwd, '')
      %{<link href="#{path}" media="#{media}" rel="stylesheet" />}
    end

    def << asset
      @assets << asset
    end

    def build
      FileUtils.mkdir_p 'public/assets'

      @manifest = @assets.each_with_object({}) do |file, hash|
        print "Compiling #{file}..."
        asset = sprockets[file]
        hash[file] = asset.digest_path
        compile_file file, "public/assets/#{asset.digest_path}"
        puts ' done'
      end

      File.write 'assets.yml', YAML.dump(manifest)
    end

    def compile_file file, output_filename
      compiled = sprockets[file].to_s + opal_boot_code(file)

      File.write output_filename, compiled
      nil
    end

    def compile file
      sprockets[file].to_s
    end

    def sprockets
      return @sprockets if defined? @sprockets

      sprockets = Sprockets::Environment.new
      Opal.paths.each do |path|
        sprockets.append_path path
      end
      sprockets.append_path 'assets/js'
      sprockets.append_path 'assets/css'

      sprockets.js_compressor = :uglifier if production?

      @sprockets = sprockets
    end

    def source_map_prefix
      '/__OPAL_SOURCE_MAPS__' 
    end

    def source_maps
      return @source_maps if defined? @source_maps

      source_map_handler = if supports_opal_config?
                             Opal::Config
                           else
                             Opal::Processor
                           end

      source_map_handler.source_map_enabled = !production? && min_opal_version?('0.8.0')

      source_maps = Opal::SourceMapServer.new(sprockets, source_map_prefix)
      if !production? && min_opal_version?('0.8.0')
        ::Opal::Sprockets::SourceMapHeaderPatch.inject!(source_map_prefix)
      end

      @source_maps = Rack::Builder.new do
        use Rack::ConditionalGet
        use Rack::ETag

        run source_maps
      end
    end

    def manifest
      return @manifest if defined? @manifest

      @manifest = YAML.load_file 'assets.yml'
      unless @manifest
        warn 'Assets manifest is broken'
      end

      @manifest
    end

    def production?
      @env == :production
    end

    def opal_boot_code file
      if min_opal_version? '0.9.0'
        Opal::Sprockets.load_asset(file, sprockets)
      elsif min_opal_version? '0.8.0'
        Opal::Processor.load_asset_code(sprockets, file)
      else
        ''
      end
    end

    def supports_opal_config?
      min_opal_version? '0.8.0'
    end

    # Check for minimum Opal version, but do it in a weird way because Array
    # implements <=> but doesn't include Comparable
    def min_opal_version? version
      (Opal::VERSION.split('.').map(&:to_i) <=> version.split('.').map(&:to_i)) >= 0
    end
  end
end

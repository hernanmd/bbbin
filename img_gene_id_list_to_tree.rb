#!/usr/bin/env ruby

require 'optparse'
require 'bio-logger'
require 'tmpdir'
require 'tempfile'

$LOAD_PATH.unshift(File.join(ENV['HOME'],'git','bioruby-taxonomy_definition_files', 'lib'))
require 'bio-taxonomy_definition_files' #has IMG taxonomy parser file

$LOAD_PATH.unshift(File.join(ENV['HOME'],'git','bioruby-img_database', 'lib'))
require 'bio-img_database'

$LOAD_PATH.unshift(File.join(ENV['HOME'],'git','bioruby-fastahack', 'lib'))
require 'bio-fastahack'

if __FILE__ == $0 #needs to be removed if this script is distributed as part of a rubygem
  SCRIPT_NAME = File.basename(__FILE__); LOG_NAME = SCRIPT_NAME.gsub('.rb','')
  
  # Parse command line options into the options hash
  options = {
    :logger => 'stderr',
    :num_threads => 1,
  }
  o = OptionParser.new do |opts|
    opts.banner = "
      Usage: #{SCRIPT_NAME} <arguments>
      
      Takes in a list of IMG identifiers, and then creates a phylogenetic tree of them with human-readable names\n\n"
      
    opts.separator "\nRequired arguments:\n\n"
    opts.on("-l", "--img-gene-list IMG_IDS_LIST_FILE", "A list of IMG identifiers that are going into the tree [required]") do |arg|
      options[:img_genes_list] =  arg
    end
    opts.on("-d", "--img-database IMG_DATABASE", "sqlite3 file that contains the data [required]") do |arg|
      options[:database_file] =  arg
    end
    opts.on("-m", "--img-metadata-file IMG_METADATA_FILENAME", "metadata file that includes the mapping from taxon identifier to taxonomic classifications [required]") do |arg|
      options[:img_metadata_file] =  arg
    end
    opts.on("-f", "--fastahack-index-basename FILE", "Where the fastahack index is located e.g. '/srv/whitlam/bio/db/img/3.5/fastahack/img3.5.finished.faa' [required]") do |arg|
      options[:img_fastahack_basename] =  arg
    end

    opts.separator "\n\tOptional arguments:\n\n"
    opts.on("-e", "--extra-proteins FASTA_FILENAME", "A fasta file of protein sequences that aren't in IMG that are to be included in the tree [optional]") do |arg|
      options[:extra_proteins_fasta_path] =  arg
    end
    opts.on("--copy-unmasked-alignment-to ALIGNED_FASTA_FILENAME", "Copy the unmasked aligned fasta file somewhere [optional]") do |arg|
      options[:unmasked_alignment_copy_file] =  arg
    end
    opts.on("--copy-masked-alignment-to ALIGNED_FASTA_FILENAME", "Copy the masked aligned fasta file somewhere [optional]") do |arg|
      options[:masked_alignment_copy_file] =  arg
    end
    opts.on('--threads NUMBER_OF_THREADS', 'Use this many threads where possible [default #{options[:num_threads]}]') do |arg|
      options[:num_threads] = arg.to_i
      unless options[:num_threads]>0
        raise "Unexpected '--threads' option given, I need an integer 1 or more: #{arg}"
      end
    end

    # logger options
    opts.separator "\n\tVerbosity:\n\n"
    opts.on("-q", "--quiet", "Run quietly, set logging to ERROR level [default INFO]") {Bio::Log::CLI.trace('error')}
    opts.on("--logger filename",String,"Log to file [default #{options[:logger]}]") { |name| options[:logger] = name}
    opts.on("--trace options",String,"Set log level [default INFO]. e.g. '--trace debug' to set logging level to DEBUG"){|s| Bio::Log::CLI.trace(s)}
  end; o.parse!
  if ARGV.length != 0 or options[:database_file].nil? or options[:img_metadata_file].nil? or options[:img_genes_list].nil?
    $stderr.puts o
    exit 1
  end
  # Setup logging. bio-logger defaults to STDERR not STDOUT, I disagree
  Bio::Log::CLI.logger(options[:logger]); log = Bio::Log::LoggerPlus.new(LOG_NAME); Bio::Log::CLI.configure(LOG_NAME)
  
  
  #Take a list of genes, and extract them from the fastahack database
  img_ids = File.open(options[:img_genes_list]).read.split("\n")
  log.info "Found #{img_ids.length} different IMG sequences that will go into the tree, e.g. #{img_ids[0]}"
  
  log.info "Extracting #{img_ids.length} IMG sequences from #{options[:img_fastahack_basename]} .."
  img_sequences = Bio::Fastahack.extract_sequences(img_ids, options[:img_fastahack_basename])
  log.info "#{img_sequences.length} sequences successfully extracted"
  
  # Get a list of better names for these genes from the local IMG db
  # Connect to the database
  Bio::IMG::Database.connect options[:database_file]
  log.info "Successfully connected to the IMG database #{options[:database_file]}"

  # Read in the taxonomy file
  taxonomies = Bio::IMG::TaxonomyDefinitionFile.read(options[:img_metadata_file])
  raise unless taxonomies.length > 1000
  log.info "Read in #{taxonomies.length} different taxonomy entries"
  
  better_img_names = {}
  img_sequences.keys.each do |img_id|
    gene = Bio::IMG::Database::Gene.where(:img_id => img_id).first
    
    desc = gene.description.match(/^\d+ (.+?) \[/)[1]

    taxons = taxonomies.select{|t| t.taxon_id==gene.taxon_id}
    unless taxons.length == 1
      log.error "Incorrect number of taxons found for #{gene.taxon_id}. Strange."
    end
    taxon = taxons[0].genus_species

    desc = "#{taxon} #{desc} #{img_id}".gsub(/[^a-zA-Z01-9_]/,'_')#probably better ways to do this cleaning
    
    better_img_names[img_id] = desc
  end
  
  # Read non-IMG fasta files
  non_img_sequences = {}
  unless options[:extra_proteins_fasta_path].nil?
    Bio::FlatFile.foreach(options[:extra_proteins_fasta_path]) do |entry|
      non_img_sequences[entry.definition] =  entry.seq.to_s
    end
    log.info "Read #{non_img_sequences.length} non-IMG sequences from #{options[:extra_proteins_fasta_path]}"
  end
  
  # Align the sequences using mafft
  tree = nil
  absolute_unmasked_alignment_copy_path = nil
  unless options[:unmasked_alignment_copy_file].nil?
    absolute_unmasked_alignment_copy_path = File.absolute_path options[:unmasked_alignment_copy_file]
  end
  absolute_masked_alignment_copy_path = nil
  unless options[:masked_alignment_copy_file].nil?
    absolute_masked_alignment_copy_path = File.absolute_path options[:masked_alignment_copy_file]
  end
  Dir.mktmpdir do |tmpdir|
    Dir.chdir(tmpdir) do
      # Write sequences to a file
      Tempfile.open('tree') do |fasta|
        non_img_sequences.each do |ident, seq|
          fasta.puts ">#{ident}"
          fasta.puts seq
        end
        img_sequences.each do |ident, seq|
          fasta.puts ">#{ident}"
          fasta.puts seq
        end
        fasta.close
        
        log.info "Running mafft on #{img_sequences.length + non_img_sequences.length} sequences.."
        `mafft --thread #{options[:num_threads]} --quiet #{fasta.path} >aligned.fa`
        
        if options[:unmasked_alignment_copy_file]
          log.info "copying unmasked alignment file to #{absolute_unmasked_alignment_copy_path}"
          `cp aligned.fa #{absolute_unmasked_alignment_copy_path}`
        end
        
        log.info "Masking the alignment to remove less than useful columns"
        `alignment_trim.rb -m 0.1 aligned.fa >aligned.masked.fa`
        
        if options[:masked_alignment_copy_file]
          log.info "copying masked alignment file to #{absolute_masked_alignment_copy_path}"
          `cp aligned.fa #{absolute_masked_alignment_copy_path}`
        end
        
        log.info "Running FastTree on these sequences"
        `FastTree aligned.masked.fa >aligned.masked.fa.tree`
        
        tree = Bio::Newick.new(File.open('aligned.masked.fa.tree').read).tree
      end
    end
  end
  
  # Rename the leaves of the tree so that they are more understandable than a simple IMG
  # identifier
  tree.leaves.each do |leaf|
    unless better_img_names[leaf.name].nil?
      leaf.name = better_img_names[leaf.name]
    end
  end
  
  # Finally, output the tree with the new, good names
  puts tree.newick
  
end #end if running as a script
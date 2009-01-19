#!/usr/bin/env ruby
# 
# Find redundant sequences in a file, to weed out strange ones

require 'bio'
require 'rubygems'
require 'reach'

hash = {}

# Collect everything
Bio::FlatFile.open($stdin).each do |seq|
  if hash[seq.seq]
    hash[seq.seq].push seq
  else
    hash[seq.seq] = [seq]
  end
end

# Print out if there is duplicates
hash.each do |key, seqs|
  if seqs.length > 1
    puts
    puts ">#{seqs.reach.definition.join("\n>")}"
    puts seqs[0].seq
  end
end
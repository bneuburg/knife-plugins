#
# Author:: Bastian Neuburger (<b.neuburger@gsi.de>)
# Copyright:: Copyright (c) 2011 GSI Darmstadt
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/knife'
require 'pathname'


# include diff method for hashes, copied from Rails
class Hash
  # Returns a hash that represents the difference between two hashes.
  #
  # Examples:
  #
  #   {1 => 2}.diff(1 => 2)         # => {}
  #   {1 => 2}.diff(1 => 3)         # => {1 => 2}
  #   {}.diff(1 => 2)               # => {1 => 2}
  #   {1 => 2, 3 => 4}.diff(1 => 2) # => {3 => 4}
  def diff(h2)
    dup.delete_if { |k, v| h2[k] == v }.merge!(h2.dup.delete_if { |k, v| has_key?(k) })
  end
end


class Chef
  class Knife
    class CookbookStatus < Knife

      deps do
        require 'chef/json_compat'
        require 'uri'
        require 'chef/cookbook_version'
        require 'digest/md5'
        require 'grit'
      end

      banner "knife cookbook status COOKBOOK [VERSION] (options)"

      option :cookbook_path,
        :short => "-o PATH:PATH",
        :long => "--cookbook-path PATH:PATH",
        :description => "A colon-separated path to look for cookbooks in",
        :proc => lambda { |o| o.split(":") }

      option :fqdn,
       :short => "-f FQDN",
       :long => "--fqdn FQDN",
       :description => "The FQDN of the host to see the file for"

      option :platform,
       :short => "-p PLATFORM",
       :long => "--platform PLATFORM",
       :description => "The platform to see the file for"

      option :platform_version,
       :short => "-V VERSION",
       :long => "--platform-version VERSION",
       :description => "The platform version to see the file for"

      option :with_uri,
        :short => "-w",
        :long => "--with-uri",
        :description => "Show corresponding URIs"

      option :gitorious,
        :short => "-g",
        :long => "--gitorious",
        :description => "Don't use local cookbook paths but gitorious for comparision."

      option :git_url,
        :short => "-U URL",
        :long => "--git-url URL",
        :description => "Remote URL under which git repositories for cookbooks are."

      option :searchcommit,
        :short => "-r",
        :long => "--search-matching-revision",
        :description => "Search the revision history of the cookbook for a commit matching the uploaded version"

      option :md5sums,
        :short => "-m",
        :long => "--md5sums",
        :description => "Print md5sums of mismatching files"

      option :threeway,
        :short => "-t",
        :long => "--threeway",
        :description => "Compare server version with local and gitorious version"

      # get checksums for the current cookbook from local git repository
      def get_checksums(commit)
        # Reset @currenthash
        @currenthash = Hash.new
        path = find_relative_git_cookbook_path
        #puts "path is '#{path}'"
        unless path == '.'
          tree = commit.tree / path
          git_checksum_hash(tree)
        else
          git_checksum_hash(commit.tree)
        end
      end

      # Recursively builds hash of relative paths of files in cookbook
      # and the according md5 checksum
      def git_checksum_hash(tree, prefix=nil)

        tree.contents.each do |obj|
          if obj.class == Grit::Blob
            item = [prefix, obj.name].join
            @currenthash[item] = Digest::MD5.hexdigest(obj.data)
          else
            git_checksum_hash(obj, [prefix, obj.name, "/"].join)
          end
        end

        return @currenthash
      end

      def find_local_cookbook

        local_path = nil
        config[:cookbook_path].each do |path|
          current_path = File.join(path, @cookbook_name)
          if File.exists? current_path and File.directory? current_path
              local_path = current_path
          end
        end
        unless local_path
          ui.fatal("Could not find cookbook #{@cookbook_name} in your cookbook path.")
          exit 1
        end
        return local_path
      end

      # recursively walk up the path looking for the git root (holds .git dir)
      def find_git_root(path)

         git_path = nil
         path = Pathname.new(path)
         while( path && !git_path ) do
             current_path = File.join(path,".git")
             if File.directory? current_path
                git_path = path
             end
             path = path.parent
         end

         return git_path
      end

      # return the path of the cookbook relative to the git root
      def find_relative_git_cookbook_path

        cb = Pathname.new(find_local_cookbook).realpath()
        git_root = Pathname.new(find_git_root(cb)).realpath()
        relative = cb.relative_path_from(git_root)
        #puts ("find cb \n#{cb} relative to path\n#{git_root} and it is \n#{relative}")
        return relative.to_s
      end

      def get_remote_cookbook

        target_dir = "/tmp/.kcbs#{rand.to_s.split(".")[1]}"
        source = "#{@git_url}/#{@cookbook_name}.git"
        fetch_it = Grit::Git.new(target_dir)
        print "Trying to acquire #{source}..."
        fetch_it.clone({ :quiet => false, :verbose => true, :progress => true, :branch => 'master' }, source, target_dir)
        Grit::Repo.new(target_dir)
      end

      def get_repos

        relevant_repos = []
        if config[:gitorious]
          return [get_remote_cookbook]
        elsif config[:threeway]
          local_repo = Grit::Repo.new(find_git_root(find_local_cookbook))
          return [get_remote_cookbook, local_repo]
        else
          return [Grit::Repo.new(find_git_root(find_local_cookbook))]
        end
      end

      # Compare to hashes and return the diff without keys you want to ignore
      def current_diff(a_hash, another_hash)

        relevant_diffs = a_hash.diff(another_hash)
        @ignored_files = ["metadata.json", ".gitignore"]
        @ignored_files.each do |file|
          relevant_diffs.delete(file)
        end
        relevant_diffs

      end

      def find_matching_commit(repo)

        print "Checking revision history"
        match = nil
        # initialize closest match with head
        closest = repo.head.commit.to_s
        best_delta = nil
        repo.commits.each do |commit|
          # Progress indicator
          print '.'

          current_hash = current_diff(get_checksums(commit), @server_checksums)
          delta = current_hash.length
          # initialize best_delta if still nil
          best_delta ||= delta

          #If we find a match, return the commit
          if delta == 0
            match = commit
            break
          end

          if delta < best_delta
            closest = commit.to_s
            best_delta = delta
          end

        end
        puts "Didn't find a matching commit, however commit #{closest} only has #{best_delta} differing files." unless match
        return match
      end


      def outputdiff(cookbook_name, checksums_source, checksums_destination)
        output("Local #{cookbook_name} cookbook and server version have mismatches.")
        file_names = current_diff(checksums_source, checksums_destination).keys
        longest_filename = file_names.max_by{ |string| string.length }

        format_string = "%-#{longest_filename.length}s  %-32s   %-32s"
        output(format_string % ["Filename", "Chef server md5sum", "Local/gitorious md5sum"])
        src_md5 = nil
        dest_md5 = nil
        file_names.each do |file|
          if checksums_source.has_key? file
            src_md5 = checksums_source[file]
          else
            src_md5 = "NONE"
          end
          if checksums_destination.has_key? file
            dest_md5 = checksums_destination[file]
          else
            dest_md5 = "NONE"
          end
          output(format_string % [file, src_md5, dest_md5] )
        end

      end

      def run
        case @name_args.length

        when 1..2
          node = Hash.new
          @git_url = config[:git_url] ||= Chef::Config[:git_url]

          if @git_url.class != String and config[:gitorious]
            ui.fatal("Please set a value for git_url in your knife config file or with the -u option!")
            exit 1
          end

          config[:cookbook_path] ||= Chef::Config[:cookbook_path]
          node[:fqdn] = config[:fqdn] if config.has_key?(:fqdn)
          node[:platform] = config[:platform] if config.has_key?(:platform)
          node[:platform_version] = config[:platform_version] if config.has_key?(:platform_version)

          class << node
            def attribute?(name)
              has_key?(name)
            end
          end

          @cookbook_name = @name_args[0]
          @cookbook_version = @name_args[1] || '_latest'

          # Hashes in the form { "relative_filename" => "checksum" }
          @server_checksums = Hash.new
          local_checksums = Hash.new

          cookbook = rest.get_rest("cookbooks/#{@cookbook_name}/#{@cookbook_version}")
          cb_hash = cookbook.to_hash
          [ 'attributes', 'definitions', 'files', 'libraries', 'providers', 'recipes', 'root_files', 'resources', 'templates'].each do |cb_part|
            unless cb_hash[cb_part].empty?
              cb_hash[cb_part].each{ |file_info| @server_checksums[file_info['path']] = file_info['checksum'] }
            end

          end

          commit_number = 0
          get_repos.each_with_index do |gitrepo, i|
            @currenthash = get_checksums(gitrepo.commits[0])
            if current_diff(@currenthash, @server_checksums).length == 0
              output("Local #{@cookbook_name} cookbook and server version (#{cookbook.version}) match.")
              next
            end
            output "Local/gitorious #{@cookbook_name} cookbook and server version (#{cookbook.version}) have a mismatch."
            outputdiff(@cookbook_name, @server_checksums, @currenthash) if config[:md5sums]
            hit = find_matching_commit(gitrepo) if config[:searchcommit]
            origin = "Gitorious"
            origin = gitrepo.path unless config[:threeway] or config[:gitorious]
            if :threeway
              origin = gitrepo.path if i == 1
            end
            puts "Found matching commit #{hit} in #{origin}." if hit
          end

        when 0
          show_usage
          ui.fatal("You must specify a cookbook name")
          exit 1
        end
      end
    end
  end
end





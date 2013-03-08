#!/usr/local/bin/ruby
require 'fileutils'

$POPDBG = true

def throw_away file
	trash_path = File.expand_path("~/.Trash/") + "/" + file
	i = 0;while File.exists? trash_path; trash_path = "%s[%i]" % [File.expand_path("~/.Trash/") + "/" + file, i=i+1] end	
	`mv "#{file}" "#{trash_path}"`
end

class Dvd
	@@volumes_paths = ['/Volumes', "/media/#{ENV['USER']}"]
	def Dvd::location
		@@volumes_paths.each do |volumes_path|
			if File.exists? volumes_path
				Dir.foreach(volumes_path) do |path|
					if(path[0]!='.')
						rtn_path = "%s/%s" % [volumes_path, path]
						if(File.directory?(rtn_path))
							if(Dir.entries(rtn_path).include?('VIDEO_TS'))
								return rtn_path
							end
						end
					end
				end
			end
		end
		raise 'Unable to locate DVD Drive.'
	end
	def Dvd::name
		return File.basename(Dvd.location)
	end	
	def Dvd::vobs(loc)
		rtn_files = []
		rtn_size = 0
		Dir.foreach(loc) do |file|
			if(File.extname(file).downcase == "\.vob")
				rtn_files << ("%s/%s" % [loc, file])
				rtn_size = rtn_size + File.size("%s/%s" % [loc, file])
			end
		end
		return rtn_files.sort, rtn_size
	end
	def Dvd::exec_lsdvd dvd_loc
		cmd = "lsdvd \"%s\" 2>&1" % [dvd_loc]
		rtn = ''
		puts "%s" % cmd.gsub(/2\>\&1$/,'')
		lsdvd = IO.popen(cmd)
		lsdvd.each("\r") do |line|
			rtn << line.clone
		end
		Process.wait
		#lsdvd.close
		if($?.exitstatus == 0)
			return rtn
		end
		return false
	end
	def Dvd::ls
		rtn = Hash.new
		rtn[:titles] = Array.new
		rtn[:longest] = "0"
		dvd_loc = Dvd.location
		res = Dvd.exec_lsdvd dvd_loc
		if(!res)
			raise "lsdvd returned bad status code."
		end
		res.each_line do |line|
			case line.to_s
			when /^Disc Title\:/
				rtn[:name] = line.split(":")[1].strip
			when /^Title\:/
				ttl = Hash.new
				line.split(',').each do |nvp|
					nv = nvp.split(":")
					case nv[0].strip
					when /^Title/
						ttl[:title] = nv[1].strip
					when /^Length/
						ttl[:length] = "%s:%s:%s" % [nv[1].strip, nv[2].strip, nv[3].split(" ")[0].strip]
						ttl[:chapters] = nv[4].strip
					when /^Cells/
						ttl[:cells] = nv[1].strip
					when /^Audio streams/
						ttl[:astrms] = nv[1].strip
					when /^Subpictures/
						ttl[:subpic] = nv[1].strip 
					end
				end
				rtn[:titles] << ttl
			when /^Longest track\:/
				rtn[:longest] = line.split(":")[1].strip
			end
		end
		return rtn
	end
end

class Dvd2Mp4
	@@use_vobcopy=true
	@@eject = true
	def validate
		if(ARGV.length > 0)
			ARGV.each do |val|
				case val
				when /^\-\-no\-vobcopy/
					@@use_vobcopy = true
				when /^\-\-no\-eject/
					@@eject = false
				when /^\-\-help/
					puts " USAGE: dvd2mp4 [options]"
					puts " Current options:"
					puts "  --no-vobcopy: do NOT use vobcopy."
					puts "    --no-eject: do NOT eject the DVD drive when done."
					puts "        --help: shows this here menu."
					exit
				else
					puts "UNKNOWN OPTION: %s" % val
				end
			end
		end	
	end
	def exec_vobcopy ttln, exp_path
		cmd = "vobcopy -n %i -o \"%s\" 2>&1" % [ttln, exp_path]
		st = Time.now
		puts "%s @ %s" % [cmd.gsub(/2\>\&1$/,''), st]
		ostr = ''
		vobcopy_log = []
		vobcopy = IO.popen(cmd)
		vobcopy.each("\r") do |line|
			vobcopy_log << line + "\r"
			if line =~ /^\[\||=/
				ostr = line.strip.gsub(/\[INFO\]/, " ") # + " "
				print ostr + ("\b" * (ostr.length + 4))
			end
		end
		Process.wait
		#vobcopy.close
		rtn = true
		tt = Time.at(Time.now - st).gmtime
		if($?.exitstatus == 0)
			puts ("SUCCESS: %s" + (" " * (ostr.length+4))) % [tt.strftime("%H:%M:%S.%3N")]
			rtn = true
		else
			puts ("FAILURE: %s - Exit code: %s" + (" " * (ostr.length+4))) % [tt.strftime("%H:%M:%S.%3N"), $?.exitstatus.to_s]
			puts "enter \"d\" to dump log, otherwise hit <enter> to exit."
			choice = $stdin.gets
			if(choice.strip == "d")
				puts vobcopy_log.join
			end
			rtn = false
		end
		return rtn
	end
	def exec_ffmpeg src_path, dst_path
		cmd = "ffmpeg -i \"%s\" -acodec libfaac -ac 2 -ab 128k -vcodec libx264 -threads 0 \"%s\" 2>&1" %
								[src_path, dst_path]
		st = Time.now
		puts "%s @ %s" % [cmd.gsub(/2\>\&1$/,''), st]
		puts "press 'q' to quit"
		progress = nil
		dur_secs = nil
		frame_rate = nil
		frames = 0
		dur_str = '00:00:00.000'
		ostr = ''
		hit_time = Time.now
		ffmpeg_log = []
		ffmpeg = IO.popen(cmd)
		ffmpeg.each("\r") do |line|
			ffmpeg_log << line + "\r"
			if((Time.now - hit_time).to_f > 30.0)
				begin
					puts " "
					ostr = "Timeout: %s" % [line.strip]
					print ostr + ("\b" * (ostr.length + 4)) 
				rescue
				end
			end
			if dur_secs == nil && line =~ /Duration:\s*(\d*):(\d*):(\d*\.\d*)/
				dur_str = $1.to_s + ":" + $2.to_s + ":" + $3.to_s
				dur_secs = ($3.to_f + ($2.to_i * 60).to_f + ($1.to_i * 3600).to_f)
				puts "Video Duration:" + dur_str + "(" + dur_sec.to_s + " secs)"
			end
			if frame_rate == nil 
				if line.strip =~ /Stream.+\, (\d+\.{0,1}\d{0,3}) fps\,/ or line =~ /Stream.+\, (\d+\.{0,1}\d{0,3}) tbc$/
					frame_rate = $1.to_f
					frames = dur_secs * frame_rate
					puts "Total Frames: %i" % frames.to_i
					puts "Frame Rate: %.3f fps" % frame_rate
				end
			end
			if line =~ /frame=\s*(\d*)/
				cframe = $1.to_i
				csecs = 0
				if line =~ /time=\s*(\d*):(\d*):(\d*\.\d*)/
					csecs = ($3.to_f + ($2.to_i * 60).to_f + ($1.to_i * 3600).to_f)
					csecs_str = $1.to_s + ":" + $2.to_s + ":" + $3.to_s
				elsif line =~ /time=\s*(\d*\.\d*)/
					csecs $1.to_f
					t = Time.at(csecs).gmtime
					csecs_str = "%0.2i:%0.2i:%0.2i.%3i" % [t.hour, t.min, t.sec, t.nsec]
				end
				if line =~ /fps=\s*(\d*)/
					cfps = $1.to_i
				else
					cfps = 0
				end
				if line =~ /bitrate=\s*(\d*\.\d*kbits)/
					br = $1
				else
					br = "???"
				end
				hit_time = Time.now
				rt = Time.at(0.0).gmtime
				if(cfps != 0)
					rt = Time.at(((frames.to_f-cframe.to_f)/cfps.to_f).to_f).gmtime
				end
				ostr = "  %3.2f%% ( %s ) @frame:%i fps:%i bitrate:%s (~%s) " % 
					[((csecs/dur_secs)*100), csecs_str, cframe, cfps, br, rt.strftime("%H:%M:%S.%3N")]
				print ostr + ("\b" * (ostr.length + 4))
			end
		end
		Process.wait
		#ffmpeg.close
		rtn = false
		tt = Time.at(Time.now - st).gmtime
		if($?.exitstatus == 0)
			puts ("SUCCESS: %s" + (" " * (ostr.length+4))) % [tt.strftime("%H:%M:%S.%3N")]
			rtn = true
		else
			puts ("FAILURE: %s - Exit code: %s" + (" " * (ostr.length+4))) % [tt.strftime("%H:%M:%S.%3N"), $?.exitstatus.to_s]
			puts "enter \"d\" to dump log, otherwise hit <enter> to exit."
			choice = $stdin.gets
			if(choice.strip == "d")
				puts ffmpeg_log.join
			end
			rtn = false
		end
		return rtn
	end
	def concat_vobs
		@cat_vob_path = "%s/%s.VOB" % [@tmp_dir_path, @dvd_name]
		i = 0;while File.exists? @cat_vob_path; @cat_vob_path = "%s/%s (%i).VOB" % [@tmp_dir_path, @dvd_name, i=i+1] end
		puts "  CONCATENATED VOB FILE: %s" % @cat_vob_path
		puts "  CONCATENATE VOBs:"
		@total_copied_bytes = 0
		copy_start_time = Time.now
		display_thread = Thread.new do
			ostr = ''
			cnt = 0
			fn = nil
			while true do
				if(fn!=Thread.current[:fn])
					if(fn!=nil)
						print("\b" * ostr.length) 
						puts "   %s" % fn
					end
					fn = Thread.current[:fn]
				end
				if(fn!=nil)
					bstr = ("\b" * ostr.length) + (" " * ostr.length) + ("\b" * ostr.length)
					print bstr
					if(cnt >= fn.length)
						cnt = 0
					end
					ostr = "   %s" % fn[0,cnt=cnt+1]
				else
					ostr = ''
				end
				print ostr
				sleep 0.05
			end
		end
		if(fn!=nil)
			print("\b" * ostr.length)
			puts "  %s" % fn
		end
		@vob_files.each do |vob_path|
			@total_bytes = File.size(vob_path)
			cmd = "cat \"%s\" >> \"%s\"" % [vob_path, @cat_vob_path]
			display_thread[:fn] = cmd
			res = `#{cmd}`
		end
		display_thread.terminate
	end
	def run
		puts "------------------------dvd2mp4------------------------"
		validate
		@start_time = Time.now
		puts " Started: %s" % @start_time.to_s
		@tmp_dir_path = ''
		begin
			@dvd_name = Dvd.name
			puts " Name: \"%s\"" % @dvd_name
			@dvd_path = Dvd.location
			puts " DVD Path: \"%s\"" % @dvd_path
			@tmp_dir_path = @dvd_name
			i = 0;while File.exists? @tmp_dir_path; @tmp_dir_path = "%s(%i)" % [@dvd_name, i=i+1] end	
			Dir.mkdir @tmp_dir_path
			puts " MKDIR: \"%s\"" % @tmp_dir_path
			if(@@use_vobcopy)
				dvd_ls = Dvd.ls
				dvd_ls[:titles].each do |ttl|
					puts "  %i: %s, %s chapters, %s cells, %s subpictures." % 
								[ttl[:title].to_i, ttl[:length], ttl[:chapters], ttl[:cells], ttl[:subpic]]
				end
				puts "   Longest title: %i" % dvd_ls[:longest]
				print "\n Choose a title to rip: "
				choice = $stdin.gets.to_i
				if(exec_vobcopy(choice, @tmp_dir_path))
					puts "Done with dvd, ejecting -=>"
					`hdiutil eject "#{@dvd_path}"`
				else
					raise "VOBCOPY FAILED"
				end
				nvob_path = "%s/%s%i-1.vob" % [@tmp_dir_path, @dvd_name, choice]
				if(!File.exists? nvob_path)
					raise "UNABLE TO CREATE NEW VOB: %s" % nvob_path
				end
				@vob_files, @vob_total_size = Dvd.vobs @tmp_dir_path
			else
				dvd_video_path = @dvd_path + "/VIDEO_TS"
				@vob_files, @vob_total_size = Dvd.vobs dvd_video_path
			end
			concat_vobs 
			if(!File.exists? @cat_vob_path)
				raise "UNABLE TO CREATE NEW CONCATENATED VOB: %s" % @cat_vob_path
			end
			nmp4_path = "%s-%i.mp4" % [@dvd_name, choice]
			i = 0;while File.exists? nmp4_path; nmp4_path = "%s-%i (%i).mp4" % [@dvd_name, choice, i=i+1] end
			if(exec_ffmpeg(@cat_vob_path, nmp4_path) == false)
				raise "UNABLE TO CREATE NEW MP4: %s" % nmp4_path
			end
		rescue => e
			puts "**ERROR: %s" % [e.message]
			if($POPDBG)
				puts "\t%s" % [e.backtrace.join("\n\t")]
			end
		ensure
			if File.exists? @tmp_dir_path
				throw_away @tmp_dir_path
			end
			end_time = Time.now
			puts "\n Ended: %s" % end_time
			puts " Total Runtime: %s" % [Time.at(end_time.to_f - @start_time.to_f).gmtime.strftime("%H:%M:%S.%3N")] 
			puts "------------------------  FIN  ------------------------"
		end
	end
end

Dvd2Mp4.new.run
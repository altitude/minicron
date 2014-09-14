require 'shellwords'
require 'escape'

module Minicron
  # Used to interact with the crontab on hosts over an ssh connection
  class Cron
    # Initialise the cron class
    #
    # @param ssh [Minicron::Transport::SSH] instance
    def initialize(ssh)
      @ssh = ssh
    end

    # Build the minicron command to be used in the crontab
    #
    # @param schedule [String]
    # @param user [String]
    # @param command [String]
    # @return [String]
    def build_minicron_command(schedule, user, command)
      # Escape the command so it will work in bourne shells
      command = Escape.shell_command(['minicron', 'run', command])
      cron_command = Escape.shell_command(['/bin/bash', '-l', '-c', command])

      user == 'root' ? "#{schedule} #{user} #{cron_command}" : "#{schedule} #{cron_command}"
    end

    # Test an SSH connection and the permissions for the crontab
    #
    # @param conn an instance of an open ssh connection
    # @return [Hash]
    def test_host_permissions(conn = nil)
      # Open an SSH connection
      conn ||= @ssh.open

      # Check if /etc is writeable
      etc_write = conn.exec!("/bin/sh -c 'test -w /etc && echo \"y\" || echo \"n\"'").strip

      # Check if /etc is executable
      etc_execute = conn.exec!("/bin/sh -c 'test -x /etc && echo \"y\" || echo \"n\"'").strip

      # Check if the crontab is readable
      crontab_read = conn.exec!("/bin/sh -c 'test -r /etc/crontab && echo \"y\" || echo \"n\"'").strip

      # Check if the crontab is writeable
      crontab_write = conn.exec!("/bin/sh -c 'test -w /etc/crontab && echo \"y\" || echo \"n\"'").strip

      {
        :connect => true,
        :etc => {
          :write => etc_write == 'y',
          :execute => etc_execute == 'y'
        },
        :crontab => {
          :read => crontab_read == 'y',
          :write => crontab_write == 'y'
        }
      }
    end

    # Used to find a string and replace it with another in the crontab by
    # using the sed command
    #
    # @param conn an instance of an open ssh connection
    # @param find [String]
    # @param replace [String]
    def find_and_replace(conn, find, replace)
      begin
        # Test the SSH connection first
        test = test_host_permissions(conn)
      rescue Exception => e
        raise Exception, "Error connecting to host, reason: #{e.message}"
      end

      # Check the connection worked
      raise Exception, "Unable to connect to host, reason: unknown" if !test[:connect]

      # Check the crontab is readable
      raise Exception, "Insufficient permissions to read from /etc/crontab" if !test[:crontab][:read]

      # Check the crontab is writeable
      raise Exception, "Insufficient permissions to write to /etc/crontab" if !test[:crontab][:write]

      # Check /etc is writeable
      raise Exception, "/etc is not writeable by the current user" if !test[:etc][:write]

      # Check /etc is executable
      raise Exception, "/etc is not executable by the current user" if !test[:etc][:execute]

      # Get the full crontab
      crontab = conn.exec!('cat /etc/crontab').to_s.strip

      # Replace the full string with the replacement string
      begin
        crontab[find] = replace
      rescue Exception => e
        raise Exception, "Unable to replace '#{find}' with '#{replace}' in the crontab, reason: #{e}"
      end

      # Get a temporary name for the crontab
      temp_crontab = "/tmp/minicron_crontab_#{Time.now.to_f}"

      # Echo the crontab back to the tmp crontab
      conn.exec!("echo #{crontab.shellescape} > #{temp_crontab}").to_s.strip

      # If it's a delete
      if replace == ''
        # Check the original line is no longer there
        grep = conn.exec!("grep -F #{find.shellescape} #{temp_crontab}").to_s.strip

        # Throw an exception if we can't see our new line at the end of the file
        if grep != replace
          fail Exception, "Expected to find nothing when grepping crontab but found #{grep}"
        end
      else
        # Check the updated line is there
        grep = conn.exec!("grep -F #{replace.shellescape} #{temp_crontab}").to_s.strip

        # Throw an exception if we can't see our new line at the end of the file
        if grep != replace
          fail Exception, "Expected to find '#{replace}' when grepping crontab but found #{grep}"
        end
      end

      # And finally replace the crontab with the new one now we now the change worked
      move = conn.exec!("/bin/sh -c 'mv #{temp_crontab} /etc/crontab && echo \"y\" || echo \"n\"'").to_s.strip

      if move != 'y'
        fail Exception, "Unable to move #{temp_crontab} to /etc/crontab, check the permissions?"
      end
    end

    # Add the schedule for this job to the crontab
    #
    # @param job [Minicron::Hub::Job] an instance of a job model
    # @param schedule [String] the job schedule as a string
    # @param conn an instance of an open ssh connection
    def add_schedule(job, schedule, conn = nil)
      # Open an SSH connection
      conn ||= @ssh.open

      # Prepare the line we are going to write to the crontab
      line = build_minicron_command(schedule, job.user, job.command)
      escaped_line = line.shellescape

      # Are we adding to the root crontab or user crontab?
      if job.user == 'root'
        echo_line = "echo #{escaped_line} >> /etc/crontab"

        # Append it to the end of the crontab
        conn.exec!(echo_line).to_s.strip

        # Check the line is there
        tail = conn.exec!('tail -n 1 /etc/crontab').to_s.strip

        # Throw an exception if we can't see our new line at the end of the file
        if tail != line
          fail Exception, "Expected to find '#{line}' at eof but found '#{tail}'"
        end
      # If we're editing the user crontab
      else
        conn.open_channel do |channel|
          channel.request_pty do |ch, success|
            unless success
              fail Exception, 'Could not obtain pty!'
            end
          end

          channel.exec 'VISUAL=vi crontab -e' do |ch, success|
            ch.send_data("GA\n#{line}\e:x\n")
          end
        end

        conn.loop
      end
    end

    # Update the schedule for this job in the crontab
    #
    # @param job [Minicron::Hub::Job] an instance of a job model
    # @param old_schedule [String] the old job schedule as a string
    # @param new_schedule [String] the new job schedule as a string
    # @param conn an instance of an open ssh connection
    def update_schedule(job, old_schedule, new_schedule, conn = nil)
      # Open an SSH connection
      conn ||= @ssh.open

      # We are looking for the current value of the schedule
      find = build_minicron_command(old_schedule, job.user, job.command)

      # And replacing it with the updated value
      replace = build_minicron_command(new_schedule, job.user, job.command)

      # Replace the old schedule with the new schedule
      find_and_replace(conn, find, replace)
    end

    # Remove the schedule for this job from the crontab
    #
    # @param job [Minicron::Hub::Job] an instance of a job model
    # @param schedule [String] the job schedule as a string
    # @param conn an instance of an open ssh connection
    def delete_schedule(job, schedule, conn = nil)
      # Open an SSH connection
      conn ||= @ssh.open

      # We are looking for the current value of the schedule
      find = build_minicron_command(schedule, job.user, job.command)

      # Replace the old schedule with nothing i.e deleting it
      find_and_replace(conn, find, '')
    end

    # Delete a job and all it's schedules from the crontab
    #
    # @param job [Minicron::Hub::Job] a job instance with it's schedules
    # @param conn an instance of an open ssh connection
    def delete_job(job, conn = nil)
      conn ||= @ssh.open

      # Loop through each schedule and delete them one by one
      # TODO: what if one schedule removal fails but others don't? Should
      # we try and rollback somehow or just return the job with half its
      # schedules deleted?
      job.schedules.each do |schedule|
        delete_schedule(job, schedule.formatted, conn)
      end
    end

    # Delete a host and all it's jobs from the crontab
    #
    # @param job [Minicron::Hub::Job] a job instance with it's schedules
    # @param conn an instance of an open ssh connection
    def delete_host(host, conn = nil)
      conn ||= @ssh.open

      # Loop through each job and delete them one by one
      # TODO: what if one schedule removal fails but others don't? Should
      # we try and rollback somehow or just return the job with half its
      # schedules deleted?
      host.jobs.each do |job|
        delete_job(job, conn)
      end
    end
  end
end

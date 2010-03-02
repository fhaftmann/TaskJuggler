#!/usr/bin/env ruby -w
# encoding: UTF-8
#
# = SheetReceiver.rb -- The TaskJuggler III Project Management Software
#
# Copyright (c) 2006, 2007, 2008, 2009, 2010 by Chris Schlaeger <cs@kde.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#

require 'mail'
require 'open4'
require 'yaml'
require 'SheetHandlerBase'

class TaskJuggler

  class SheetReceiver < SheetHandlerBase

    def initialize(appName, type)
      super(appName)

      @sheetType = type
      # The following settings must be set by the deriving class.
      # Sheet type specific option for tj3client
      @tj3clientOption = nil
      # Base directory to store received sheets
      @sheetDir = nil
      # Base directory where to find the resource file.
      @templateDir = nil
      # Directory to store the failed emails.
      @failedMailsDir = nil
      # File that holds the acceptable signatures.
      @signatureFile = nil
      # The log file
      @logFile = nil

      # Regular expressions to identify a status sheet.
      @sheetHeader = /^[ ]*statussheet\s([a-z][a-z0-9_]*)\s([0-9]*-[0-9]*-[0-9]*)/
      # Regular expression to extract the sheet signature (date).
      @signatureFilter = /^[ ]*statussheet\s[a-z][a-z0-9_]*\s([0-9:\-+]*)/
      # The email address of the submitter of the sheet.
      @submitter = nil
      # The resource ID of the submitter.
      @resourceId = nil
      # The stdout content from tj3client
      @report = nil
      # The stderr content from tj3client
      @warnings = nil

      # The extracted sheet text.
      @sheet = nil
      # The end date of the reporting period.
      @date = nil
    end

    # Read the sheet from $stdin in email format. Extract the sheet from the
    # attachments or body and check it. If ok, send back a summary, otherwise
    # the error message.
    # The actual check is done by a tj3 server process that is accessed via
    # tj3client.
    def processEmail
      setWorkingDir

      createDirectories

      mail = Mail.new($stdin.read)

      # Who sent this email?
      @submitter = mail.from.respond_to?('[]') ? mail.from[0] : mail.from
      # Getting the message ID.
      @messageId = mail.message_id || 'unknown'
      info("Processing #{@sheetType} sheet from #{@submitter} " +
           "with ID #{@messageId}")

      # Store the mail in the failedMailsDir in case something goes wrong.
      File.open("#{@failedMailsDir}/#{@messageId}", 'w') do |f|
        f.write(mail)
      end

      # First we search the attachments and then the body.
      mail.attachments.each do |attachment|
        # We are looking for an attached file with a .tji extension.
        fileName = attachment.filename
        next unless fileName && fileName[-4..-1] == '.tji'

        # Further inspect the attachment. If we could process it, we are done.
        return true if processSheet(attachment.body.decoded)
      end
      # None of the attachements worked, so let's try the mail body.
      return true if processSheet(mail.body.decoded)

      error(<<"EOT"
No #{@sheetType} sheet found in email. Please make sure the header syntax is
correct and contained in a single line that starts at the begining of the
line. If you had the #{@sheetType} sheet attached, the file name must have a
'.tji' extension to be found.
EOT
           )
    end

    private

    # Isolate the actual syntax from _sheet_ and process it.
    def processSheet(sheet)
      # Store the detected sheet so we can include it with error reports if
      # needed.
      @sheet = cutOut(fixLineBreaks(sheet))
      # A valid sheet must have the poper header line.
      if @sheetHeader.match(@sheet)
        checkSignature(@sheet)
        # Extract the resource ID and the end date from the sheet.
        matches = @sheetHeader.match(@sheet)
        @resourceId, @date = matches[1..2]
        # Email answers will only go the email address on file!
        @submitter = getResourceEmail(@resourceId)
        info("Found sheet for #{@resourceId} dated #{@date}")
        # Ok, found. Now check the full sheet.
        if checkSheet(@sheet)
          # Everything is fine. Store it away.
          fileSheet(@sheet)
          # Remove the mail from the failedMailsDir
          File.delete("#{@failedMailsDir}/#{@messageId}")
          return true
        end
      end
    end

    def checkSheet(sheet)
      err = ''
      status = nil
      begin
        command = "tj3client --silent #{@tj3clientOption} ."
        status = Open4.popen4(command) do |pid, stdin, stdout, stderr|
          # Send the report to the tj3client process via stdin.
          stdin.write(sheet)
          stdin.close
          @report = stdout.read
          @warnings = stderr.read
        end
      rescue
        fatal("Cannot check #{@sheetType} sheet: #{$!}")
      end
      return true if status.exitstatus == 0

      # The exit status was not 0. The stderr output should not be empty and
      # will contain error and warning messages.
      error(@warnings)
    end

    def fileSheet(sheet)
      # Create the appropriate directory structure if it doesn't exist.
      dir = "#{@sheetDir}/#{@date}"
      fileName = ''
      begin
        unless File.directory?(dir)
          Dir.mkdir(dir)
          addToScm('Adding new directory', dir)
        end
        fileName = "#{dir}/#{@resourceId}_#{@date}.tji"
        File.open(fileName, 'w') { |f| f.write(sheet) }
        addToScm("Adding/updating #{fileName}", fileName)
      rescue
        fatal("Cannot store #{@sheetType} sheet #{fileName}: #{$!}")
        return false
      end

      # Create or update the file that includes all *.tji in the directory.
      generateInclusionFile(dir)

      text = <<"EOT"
Report from #{getResourceName} for the period ending #{@date}:

EOT

      # Add warnings if we had any.
      unless @warnings.empty?
        text += <<"EOT"
Your report does contain some issues that you may want to fix or address with
your manager or project manager:

#{@warnings}

EOT
      end

      # Append the pretty printed version of the submitted status sheet.
      text += @report

      # Send out the email.
      sendEmail(@submitter, "Report from #{getResourceName}", text)
      true
    end

    # Generate or update a file the contains 'include' statements for all the
    # .tji files in the provided directory. The generated file will be in this
    # directory as well.
    def generateInclusionFile(dir)
      pwd = Dir.pwd
      begin
        Dir.chdir(dir)
        File.open('all.tji', 'w') do |file|
          Dir.glob('*.tji').each do |tji|
            file.puts("include '#{tji}' { }") unless tji == 'all.tji'
          end
        end
      rescue
        error("Can't create inclusion file: #{$!}")
      ensure
        Dir.chdir(pwd)
      end
      # Report the change to the SCM handler.
      addToScm('Adding/updating summary include file.', "#{dir}/all.tji")
    end

    def checkSignature(sheet)
      if matches = @signatureFilter.match(sheet)
        interval = matches[1]
      else
        fatal("No #{@sheetType}sheet header found")
      end

      acceptedIntervals = []
      if File.exist?(@signatureFile)
        File.open(@signatureFile, 'r') do |file|
          acceptedIntervals = file.gets
        end
      else
        error("#{@signatureFile} does not exist yet.")
      end

      unless acceptedIntervals.include?(interval)
        error(<<"EOT"
The reporting period #{interval}
was not accepted!  Either you have modified the sheet header,
you are submitting the sheet too late or too early.
EOT
             )
      end
    end

    def createDirectories
      [ @sheetDir, @failedMailsDir ].each do |dir|
        unless File.directory?(dir)
          info("Creating directory #{dir}")
          Dir.mkdir(dir)
        end
      end
    end

    def error(message)
      $stderr.puts message if @outputLevel >= 1

      log('ERROR', "#{message}") if @logLevel >= 1

      # Append the submitted sheet for further tries. We may run into encoding
      # errors here. In this case we send the answer without the incoming time
      # sheet.
      begin
        message += "\n" + @sheet if @sheet
      rescue
      end

      sendEmail(@submitter, 'Your time sheet submission failed!', message)

      exit 1
    end

    def fatal(message)
      log('FATAL', "#{message}")

      # Append the submitted sheet for further tries.
      message += "\n" + @sheet if @sheet

      sendEmail(@submitter, 'Temporary server error', <<"EOT"
We are sorry! The #{@sheetType} sheet server detected a configuration
problem and is temporarily out of service. The administrator
has been notified and will try to rectify the situation as
soon as possible. Please re-submit your #{@sheetType} sheet later!
EOT
               )
      exit 1
    end


    # Load tye resources.yml YAML file into the @resourceList variable.
    # The format is Array with one entry per resource. The entry is an Array
    # with 3 fields: ID, name and email. All fields are String objects.
    def getResourceList
      fatal('@date not set') unless @date

      fileName = "#{@templateDir}/#{@date}/resources.yml"
      begin
        @resourceList = YAML.load(File.read(fileName))
        info("#{@resourceList.length} resources loaded")
      rescue
        error("Cannot read resource file #{fileName}: #{$!}")
      end
      @resourceList
    end

    def getResourceEmail(id = @resourceId)
      getResourceList unless @resourceList

      @resourceList.each do |resource|
        return resource[2] if resource[0] == id
      end
      error("Resource ID '#{id}' not found in list")
    end

    def getResourceName(id = @resourceId)
      getResourceList unless @resourceList

      @resourceList.each do |resource|
        return resource[1] if resource[0] == id
      end
      error("Resource ID '#{id}' not found in list")
    end

  end

end
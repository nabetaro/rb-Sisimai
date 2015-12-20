module Sisimai
  module MTA
    # Sisimai::MTA::V5sendmail parses a bounce email which created by Sendmail
    # version 5. Methods in the module are called from only Sisimai::Message.
    module V5sendmail
      # Imported from p5-Sisimail/lib/Sisimai/MTA/V5sendmail.pm
      class << self
        require 'sisimai/mta'
        require 'sisimai/rfc5322'

        Re0 = {
          :from    => %r/\AMail Delivery Subsystem/,
          :subject => %r/\AReturned mail: [A-Z]/,
        }
        # Error text regular expressions which defined in src/savemail.c
        #   savemail.c:485| (void) fflush(stdout);
        #   savemail.c:486| p = queuename(e->e_parent, 'x');
        #   savemail.c:487| if ((xfile = fopen(p, "r")) == NULL)
        #   savemail.c:488| {
        #   savemail.c:489|   syserr("Cannot open %s", p);
        #   savemail.c:490|   fprintf(fp, "  ----- Transcript of session is unavailable -----\n");
        #   savemail.c:491| }
        #   savemail.c:492| else
        #   savemail.c:493| {
        #   savemail.c:494|   fprintf(fp, "   ----- Transcript of session follows -----\n");
        #   savemail.c:495|   if (e->e_xfp != NULL)
        #   savemail.c:496|       (void) fflush(e->e_xfp);
        #   savemail.c:497|   while (fgets(buf, sizeof buf, xfile) != NULL)
        #   savemail.c:498|       putline(buf, fp, m);
        #   savemail.c:499|   (void) fclose(xfile);
        Re1 = {
          :begin  => %r/\A\s+[-]+ Transcript of session follows [-]+\z/,
          :error  => %r/\A[.]+ while talking to .+[:]\z/,
          :rfc822 => %r{\A\s+-----\s(?:
             Unsent[ ]message[ ]follows
            |No[ ]message[ ]was[ ]collected
            )\s-----
          }x,
          :endof  => %r/\A__END_OF_EMAIL_MESSAGE__\z/,
        }
        Indicators = Sisimai::MTA.INDICATORS
        LongFields = Sisimai::RFC5322.LONGFIELDS
        RFC822Head = Sisimai::RFC5322.HEADERFIELDS

        def description; return 'Sendmail version 5'; end
        def smtpagent;   return 'V5sendmail'; end
        def headerlist;  return []; end
        def pattern;     return Re0; end

        # Parse bounce messages from Sendmail version 5
        # @param         [Hash] mhead       Message header of a bounce email
        # @options mhead [String] from      From header
        # @options mhead [String] date      Date header
        # @options mhead [String] subject   Subject header
        # @options mhead [Array]  received  Received headers
        # @options mhead [String] others    Other required headers
        # @param         [String] mbody     Message body of a bounce email
        # @return        [Hash, Nil]        Bounce data list and message/rfc822
        #                                   part or nil if it failed to parse or
        #                                   the arguments are missing
        def scan(mhead, mbody)
          return nil unless mhead
          return nil unless mbody
          return nil unless mhead['subject'] =~ Re0[:subject]

          dscontents = []; dscontents << Sisimai::MTA.DELIVERYSTATUS
          hasdivided = mbody.split("\n")
          rfc822next = { 'from' => false, 'to' => false, 'subject' => false }
          rfc822part = ''     # (String) message/rfc822-headers part
          previousfn = ''     # (String) Previous field name
          readcursor = 0      # (Integer) Points the current cursor position
          recipients = 0      # (Integer) The number of 'Final-Recipient' header
          responding = []     # (Array) Responses from remote server
          commandset = []     # (Array) SMTP command which is sent to remote server
          anotherset = {}     # (Hash) Another error information
          errorindex = -1     # (Integer)
          v = nil

          hasdivided.each do |e|
            if readcursor == 0
              # Beginning of the bounce message or delivery status part
              if e =~ Re1[:begin]
                readcursor |= Indicators[:'deliverystatus']
                next
              end
            end

            if readcursor & Indicators[:'message-rfc822'] == 0
              # Beginning of the original message part
              if e =~ Re1[:rfc822]
                readcursor |= Indicators[:'message-rfc822']
                next
              end
            end

            if readcursor & Indicators[:'message-rfc822'] > 0
              # After "message/rfc822"
              if cv = e.match(/\A([-0-9A-Za-z]+?)[:][ ]*.+\z/)
                # Get required headers only
                lhs = cv[1].downcase
                previousfn = '';
                next unless RFC822Head.key?(lhs)

                previousfn  = lhs
                rfc822part += e + "\n"

              elsif e =~ /\A\s+/
                # Continued line from the previous line
                next if rfc822next[previousfn]
                rfc822part += e + "\n" if LongFields.key?(previousfn)

              else
                # Check the end of headers in rfc822 part
                next unless LongFields.key?(previousfn)
                next unless e.empty?
                rfc822next[previousfn] = true
              end

            else
              # Before "message/rfc822"
              next if readcursor & Indicators[:'deliverystatus'] == 0
              next if e.empty?

              #    ----- Transcript of session follows -----
              # While talking to smtp.example.com:
              # >>> RCPT To:<kijitora@example.org>
              # <<< 550 <kijitora@example.org>, User Unknown
              # 550 <kijitora@example.org>... User unknown
              # 421 example.org (smtp)... Deferred: Connection timed out during user open with example.org
              v = dscontents[-1]

              if cv = e.match(/\A\d{3}\s+[<]([^ ]+[@][^ ]+)[>][.]{3}\s*(.+)\z/)
                # 550 <kijitora@example.org>... User unknown
                if v['recipient']
                  # There are multiple recipient addresses in the message body.
                  dscontents << Sisimai::MTA.DELIVERYSTATUS
                  v = dscontents[-1]
                end
                v['recipient'] = cv[1]
                v['diagnosis'] = cv[2]

                if responding[recipients]
                  # Concatenate the response of the server and error message
                  v['diagnosis'] ||= ''
                  v['diagnosis']  += ': ' + responding[recipients]
                end
                recipients += 1

              elsif cv = e.match(/\A[>]{3}\s*([A-Z]{4})\s*/)
                # >>> RCPT To:<kijitora@example.org>
                commandset[recipients] = cv[1]

              elsif cv = e.match(/\A[<]{3}[ ]+(.+)\z/)
                # <<< Response
                # <<< 501 <shironeko@example.co.jp>... no access from mail server [192.0.2.55] which is an open relay.
                # <<< 550 Requested User Mailbox not found. No such user here.
                responding[recipients] = cv[1]

              else
                # Detect SMTP session error or connection error
                next if v['sessionerr']

                if e =~ Re1[:error]
                  # ----- Transcript of session follows -----
                  # ... while talking to mta.example.org.:
                  v['sessionerr'] = true
                  next
                end

                if cv = e.match(/\A\d{3}\s+.+[.]{3}\s*(.+)\z/)
                  # 421 example.org (smtp)... Deferred: Connection timed out during user open with example.org
                  anotherset['diagnosis'] = cv[1]
                end
              end
            end
          end
          return unless readcursor & Indicators[:'message-rfc822']

          if recipients == 0
            # Get the recipient address from the original message
            if cv = rfc822part.match(/^To: (.+)$/m)
              # The value of To: header in the original message
              dscontents[0]['recipient'] = Sisimai::Address.s3s4(cv[1])
              recipients = 1
            end
          end
          return nil if recipients == 0
          require 'sisimai/string'

          dscontents.map do |e|
            errorindex += 1

            if mhead['received'].size > 0
              # Get localhost and remote host name from Received header.
              r0 = mhead['received']
              ['lhost', 'rhost'].each { |a| e[a] ||= '' }
              e['lhost'] = Sisimai::RFC5322.received(r0[0]).shift if e['lhost'].empty?
              e['rhost'] = Sisimai::RFC5322.received(r0[-1]).pop  if e['rhost'].empty?
            end
            e['spec']  ||= 'SMTP'
            e['agent']   = Sisimai::MTA::V5sendmail.smtpagent
            e['command'] = commandset[errorindex] || ''

            if anotherset['diagnosis'] && anotherset['diagnosis'].size > 0
              # Copy alternative error message
              e['diagnosis'] ||= anotherset['diagnosis']

            else
              # Set server response as a error message
              e['diagnosis'] ||= responding[errorindex]
            end
            e['diagnosis'] = Sisimai::String.sweep(e['diagnosis'])

            unless e['recipient'] =~ /\A[^ ]+[@][^ ]+\z/
              # @example.jp, no local part
              if cv = e['diagnosis'].match(/[<]([^ ]+[@][^ ]+)[>]/)
                # Get email address from the value of Diagnostic-Code header
                e['recipient'] = cv[1]
              end
            end
            e.delete('sessionerr')
            e.each_key { |a| e[a] ||= '' }
          end

          return { 'ds' => dscontents, 'rfc822' => rfc822part }
        end

      end
    end
  end
end

require 'net/ssh'
require 'metasploit/framework/login_scanner'

module Metasploit
  module Framework
    module LoginScanner

      # This is the LoginScanner class for dealing with the Secure Shell protocol and PKI.
      # It is responsible for taking a single target, and a list of credentials
      # and attempting them. It then saves the results. In this case it is expecting
      # SSH private keys for the private credential.
      class SSHKey
        include ActiveModel::Validations

        #
        # CONSTANTS
        #

        VERBOSITIES = [
            :debug,
            :info,
            :warn,
            :error,
            :fatal
        ]

        # @!attribute connection_timeout
        #   @return [Fixnum] The timeout in seconds for a single SSH connection
        attr_accessor :connection_timeout
        # @!attribute cred_details
        #   @return [Array] An array of Credential objects
        attr_accessor :cred_details
        # @!attribute failures
        #   @return [Array] Array of of result objects that failed
        attr_accessor :failures
        # @!attribute host
        #   @return [String] The IP address or hostname to connect to
        attr_accessor :host
        # @!attribute port
        #   @return [Fixnum] The port to connect to
        attr_accessor :port
        # @!attribute proxies
        #   @return [String] The proxy directive to use for the socket
        attr_accessor :proxies
        # @!attribute ssh_socket
        #   @return [Net::SSH::Connection::Session] The current SSH connection
        attr_accessor :ssh_socket
        # @!attribute stop_on_success
        #   @return [Boolean] Whether the scanner should stop when it has found one working Credential
        attr_accessor :stop_on_success
        # @!attribute successes
        #   @return [Array] Array of results that successfully logged in
        attr_accessor :successes
        # @!attribute verbosity
        #   The verbosity level for the SSH client.
        #
        #   @return [Symbol] An element of {VERBOSITIES}.
        attr_accessor :verbosity

        validates :connection_timeout,
                  presence: true,
                  numericality: {
                      only_integer:             true,
                      greater_than_or_equal_to: 1
                  }

        validates :cred_details, presence: true

        validates :host, presence: true

        validates :port,
                  presence: true,
                  numericality: {
                      only_integer:             true,
                      greater_than_or_equal_to: 1,
                      less_than_or_equal_to:    65535
                  }

        validates :stop_on_success,
                  inclusion: { in: [true, false] }

        validates :verbosity,
                  presence: true,
                  inclusion: { in: VERBOSITIES }

        validate :host_address_must_be_valid

        validate :validate_cred_details

        # @param attributes [Hash{Symbol => String,nil}]
        def initialize(attributes={})
          attributes.each do |attribute, value|
            public_send("#{attribute}=", value)
          end
          self.successes= []
          self.failures=[]
        end

        # This method attempts a single login with a single credential against the target
        # @param credential [Credential] The credential object to attmpt to login with
        # @return [Metasploit::Framework::LoginScanner::Result] The LoginScanner Result object
        def attempt_login(credential)
          ssh_socket = nil
          opt_hash = {
              :auth_methods  => ['publickey'],
              :port          => port,
              :disable_agent => true,
              :key_data      => credential.private,
              :config        => false,
              :verbose       => verbosity,
              :proxies       => proxies
          }

          result_options = {
              private: credential.private,
              public: credential.public,
              realm: nil
          }
          begin
            ::Timeout.timeout(connection_timeout) do
              ssh_socket = Net::SSH.start(
                  host,
                  credential.public,
                  opt_hash
              )
            end
          rescue ::EOFError, Net::SSH::Disconnect, Rex::AddressInUse, Rex::ConnectionError, ::Timeout::Error
            result_options.merge!( proof: nil, status: :connection_error)
          rescue Net::SSH::Exception
            result_options.merge!( proof: nil, status: :failed)
          end

          unless result_options.has_key? :status
            if ssh_socket
              proof = gather_proof
              result_options.merge!( proof: proof, status: :success)
            else
              result_options.merge!( proof: nil, status: :failed)
            end
          end

          ::Metasploit::Framework::LoginScanner::Result.new(result_options)

        end

        # Run all the login attempts against the target.
        #
        # This method calls {#attempt_login} once for each credential in
        # {#cred_details}.  Results are stored in {#successes} and {#failures}.
        # If a block is given, each result will be yielded as we go.
        #
        # @yieldparam result [Result] The frozen {Result} object associated
        #   with each attempt
        # @yieldreturn [void]
        # @return [void]
        def scan!
          valid!
          cred_details.each do |credential|
            result = attempt_login(credential)
            result.freeze

            yield result if block_given?

            if result.success?
              successes << result
              break if stop_on_success
            else
              failures << result
            end
          end
        end

        # @raise [Metasploit::Framework::LoginScanner::Invalid] if the attributes are not valid on the scanner
        def valid!
          unless valid?
            raise Metasploit::Framework::LoginScanner::Invalid.new(self)
          end
        end

        private

        # This method attempts to gather proof that we successfuly logged in.
        # @return [String] The proof of a connection, May be empty.
        def gather_proof
          proof = ''
          begin
            Timeout.timeout(5) do
              proof = ssh_socket.exec!("id\n").to_s
              if(proof =~ /id=/)
                proof << ssh_socket.exec!("uname -a\n").to_s
              else
                # Cisco IOS
                if proof =~ /Unknown command or computer name/
                  proof = ssh_socket.exec!("ver\n").to_s
                else
                  proof << ssh_socket.exec!("help\n?\n\n\n").to_s
                end
              end
            end
          rescue ::Exception
          end
          proof
        end

        # This method validates that the host address is both
        # of a valid type and is resolveable.
        # @return [void]
        def host_address_must_be_valid
          unless host.kind_of? String
            errors.add(:host, "must be a string")
          end
          begin
            resolved_host = ::Rex::Socket.getaddress(host, true)
            if host =~ /^\d{1,3}(\.\d{1,3}){1,3}$/
              unless host =~ Rex::Socket::MATCH_IPV4
                errors.add(:host, "could not be resolved")
              end
            end
            host = resolved_host
          rescue
            errors.add(:host, "could not be resolved")
          end
        end

        # This method validates that the credentials supplied
        # are all valid.
        # @return [void]
        def validate_cred_details
          if cred_details.kind_of? Array
            cred_details.each do |detail|
              unless detail.kind_of? Metasploit::Framework::LoginScanner::Credential
                errors.add(:cred_details, "has invalid element #{detail.inspect}")
                next
              end
              unless detail.valid?
                errors.add(:cred_details, "has invalid element #{detail.inspect}")
              end
            end
          else
            errors.add(:cred_details, "must be an array")
          end
        end



      end

    end
  end
end
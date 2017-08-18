require 'socket'
require 'openssl'
require 'json'

module APNS
  class Application

    attr_accessor :host, :pem_location, :pem_password, :persistent, :port, :socket, :ssl_connection

    DEFAULT_APNS_HOST = 'gateway.sandbox.push.apple.com'.freeze

    DEFAULT_APNS_PORT = 2195.freeze

    GATEWAY = 'gateway'.freeze

    FEEDBACK = 'feedback'.freeze

    APNS_TCP_REMOTE_PORT = 2196.freeze

    def initialize (host = DEFAULT_APNS_HOST, pem_location = nil, pem_password = nil, port = DEFAULT_APNS_PORT)
      @host = host unless host == nil
      @pem_location = pem_location unless pem_location == nil
      @pem_password = pem_password unless pem_password == nil
      @port = port unless port == nil

      @persistent = false
      @mutex = Mutex.new
      @retries = 3 # TODO: check if we really need this

      @socket = nil
      @ssl_connection = nil
    end

    def start_persistence
      @persistent = true
    end

    def stop_persistence
      @persistent = false

      @ssl_connection.close if @ssl_connection
      @socket.close if @socket
    end

    def send_notification(device_token, message)
      notification = APNS::Notification.new(device_token, message)
      send_notifications([notification])
    end

    def send_notifications(notifications)
      @mutex.synchronize do
        with_connection do
          notifications.each do |notification|
            @ssl_connection.write(notification.packaged_notification)
          end
        end
      end
    end

    def feedback
      @socket, @ssl_connection = feedback_connection

      apns_feedback = []

      while line = @ssl_connection.read(38) # Read lines from the socket
        line.strip!
        f = line.unpack('N1n1H140')
        apns_feedback << { timestamp: Time.at(f[0]), token: f[2] }
      end

      @ssl_connection.close if @ssl_connection
      @socket.close if @socket

      apns_feedback
    end

    protected
      def with_connection
        attempts = 1

        begin
          # If no @ssl is created or if @ssl is closed we need to start it
          if @ssl_connection.nil? || @socket.nil? || @ssl_connection.closed? || @socket.closed?
            @socket, @ssl_connection = open_connection
          end

          yield
        rescue StandardError, Errno::EPIPE
          raise unless attempts < @retries

          @ssl_connection.close if @ssl_connection
          @socket.close if @socket

          attempts += 1
          retry
        end

        # Only force close if not persistent
        unless @persistent
          @ssl_connection.close
          @ssl_connection = nil
          @socket.close
          @socket = nil
        end
      end

      def open_connection
        start_connection(@host)
      end

      def feedback_connection
        remote_host = @host.gsub(GATEWAY, FEEDBACK)
        start_connection(remote_host)
      end

      def start_connection(host)
        raise Exceptions::PushmeupException.new(I18n.t('pushmeup.errors.internal.pem_is_not_set')) unless @pem_location
        raise Exceptions::PushmeupException.new(I18n.t('pushmeup.errors.internal.pem_does_not_exist')) unless File.exists?(@pem_location)

        context = OpenSSL::SSL::SSLContext.new
        context.cert = OpenSSL::X509::Certificate.new(File.read(@pem_location))
        context.key = OpenSSL::PKey::RSA.new(File.read(@pem_location), @pem_password)

        socket = TCPSocket.new(host, APNS_TCP_REMOTE_PORT)
        ssl = OpenSSL::SSL::SSLSocket.new(socket, context)
        ssl.connect

        return socket, ssl
      end
  end
end

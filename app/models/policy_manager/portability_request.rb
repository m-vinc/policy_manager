require "aasm"
require 'zip'

module PolicyManager
  class PortabilityRequest < PolicyManager::ApplicationRecord
    include AASM

    belongs_to :owner, polymorphic: true

    mount_uploader :attachement, AttachementUploader

    after_create :change_state_if_needed
    after_create :notify_created

    validate :only_one_pending_request, on: :create

    def only_one_pending_request
      self.errors.add(:owner_id, :not_unique) if owner.portability_requests.where(state: [:waiting_for_approval, :pending, :running], requested_by: self.requested_by).count > 0
    end

    aasm column: :state do
      state :waiting_for_approval, :initial => true
      state :pending
      state :running
      state :done
      state :denied
      state :canceled
  
      event :approve, after_commit: [:on_approval_callback, :generate_json] do
         transitions :from => :waiting_for_approval, :to => :pending
      end

      event :cancel do
        transitions from: :waiting_for_approval, :to => :canceled
      end

      event :deny, after_commit: :notify_denied do
        transitions :from => :waiting_for_approval, :to => :denied
      end
  
      event :run, after_commit: :create_on_other_services do
        transitions :from => :pending, :to => :running
      end
      
      event :done, after_commit: :notify_completed do
        transitions :from => :running, :to => :done
      end
    end

    def change_state_if_needed
      self.approve! if Config.skip_portability_request_approval
    end

    def create_on_other_services
      return unless notify_other_services?
      Config.other_services.each do |name, _|
        call_service(name)
      end
    end

    def call_service(service)
      perform_async(service)
    end

    def async_call_service(service_name)
      service = Config.other_services[service_name.to_sym]
      if service.respond_to?('[]', :host) # services must have a host in configuration file
        response = HTTParty.post(service[:host] + Config.portability_path, body: encrypted_params_for_service(service_name), timeout: 1.minute).response
      else
        return false
      end

      case response.code.to_i
      when 200..299
        return response
      when 404
        return response
      when 401
        raise "service_name '#{service_name}' returned unauthorized"
      when 422
        raise "service_name '#{service_name}' cannot process params, and returned #{response.body}"
      when 500..599
        raise "endpoint '#{service_name}' have an internal server error, and returned #{response.body}"
      else
        raise "endpoint '#{service_name}' returned unhandled status code (#{response.code}) with body #{response.body}, aborting."
      end
    end

    def self.encrypted_params(user_identifier, token = PolicyManager::Config.token)
      hash = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha512'), token, user_identifier)
      {user: user_identifier, hash: hash}
    end

    def encrypted_params_for_service(service_name)
      user_identifier = owner.send(PolicyManager::Config.finder)
      PortabilityRequest.encrypted_params(user_identifier, Config.other_services[service_name.to_sym][:token])
    end

    def my_encrypted_params
      user_identifier = owner.send(PolicyManager::Config.finder)
      PortabilityRequest.encrypted_params(user_identifier)
    end

    def notify_created
      return unless self.requested_by.nil?
      send_mail('portability_requested')
      send_admin_mail('portability_requested')
    end

    def notify_denied
      send_mail('portability_denied')
    end

    def notify_completed
      send_mail('portability_completed')
      self.update(expire_at: 2.days.from_now)
      perform_job_at 'delete_generated_json', 2.days.from_now
    end

    def on_approval_callback
      if PolicyManager::Config.on_portability_approval
        PolicyManager::Config.on_portability_approval.call(self)
      end
    end

    def generate_json
      perform_async
    end

    def delete_generated_json
      self.remove_attachement!
      self.save
    end

    def async_generate_json
      self.run! unless self.running?
      file_path = File.join(Rails.root, 'tmp', 'generate_data_dump')
      FileUtils.mkdir_p(file_path) unless File.exists?(file_path)
      file_name = File.join(file_path, "#{self.id.to_s}.json")
      file = File.new(file_name, 'w')
      user_data = Registery.new.data_dump_for(owner).to_json

      begin
        file.flush
        file.write(user_data)
        file.close
        zipfile_name = file_path + "#{Devise.friendly_token}.zip"
        Zip::File.open(zipfile_name, Zip::File::CREATE) do |zipfile|
          zipfile.add("#{self.id.to_s}.json", file)
        end
        self.update(attachement: File.open(zipfile_name))
      ensure
        File.delete(file)
        File.delete(zipfile_name)
      end
      self.done!
    end

  end
end

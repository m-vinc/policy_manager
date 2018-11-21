module PolicyManager
  class ApplicationController < ActionController::Base
    layout 'policy_manager'
    skip_before_action :authenticate_user!, raise: false
    before_filter :set_current_user
    before_filter :merge_abilities


    private

    def merge_abilities
      current_ability.merge(PolicyManager::Ability.new(@current_user))
    end
    
    def set_current_user
      @current_user = current_user
    end
  end
end
module RailsAdmin
  module Config
    module Actions
      class ConfirmUser < RailsAdmin::Config::Actions::Base
        RailsAdmin::Config::Actions.register(self)

        register_instance_option :member do
          true
        end

        register_instance_option :link_icon do
          "fas fa-user-check"
        end

        register_instance_option :visible? do
          authorized? &&
            bindings[:object].present? &&
            !bindings[:object].confirmed?
        end

        register_instance_option :http_methods do
          %i[get post]
        end

        register_instance_option :controller do
          proc do
            if request.get?
              render @action.template_name
              next
            end

            if @object.confirmed?
              flash[:notice] = "#{@object.email} is already confirmed."
            else
              @object.confirm
              Rails.logger.info(
                "User manually confirmed user_id=#{@object.id} " \
                "admin_user_id=#{current_user.id}"
              )
              flash[:success] = "#{@object.email} has been confirmed."
            end

            redirect_to index_path
          end
        end
      end
    end
  end
end

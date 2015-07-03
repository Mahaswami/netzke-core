class NetzkeController < ApplicationController

  # Action for Ext.Direct RPC calls
    include NewRelic::Agent::Instrumentation::ControllerInstrumentation

    def direct
      result=""
      error=false
      if params['_json'] # this is a batched request
        txn_name = if agency.present?
                     "#{agency}/batch_request"
                   else
                     "batch_request"
                   end
        NewRelic::Agent.set_transaction_name txn_name
        params['_json'].each do |batch|
          result += result.blank? ? '[' : ', '
          begin
            result += invoke_endpoint_and_do_nr(batch)
          rescue Exception  => e
            Rails.logger.error "!!! Netzke: Error invoking endpoint: #{batch[:act]} #{batch[:method].underscore} #{batch[:data].inspect} #{batch[:tid]}\n"
            Rails.logger.error e.message
            Rails.logger.error e.backtrace.join("\n")
            error=true
            break;
          end
        end
        result+=']'
      else # this is a single request
        formatted_url = if params[:method] == "deliverComponent"
                          "#{params[:act]}/deliver_#{params[:data][0][:name]}"
                        else
                          "#{params[:act]}/#{params[:method]}"
                        end
        txn_name = if agency.present?
                     "#{agency}/#{formatted_url}"
                   else
                     formatted_url
                   end
        NewRelic::Agent.set_transaction_name txn_name
        result =  _invoke_endpoint params
      end
       render :text => result, :layout => false, :status => error ? 500 : 200
    end


    def agency
      if (User.current and User.current.office_staff?)
           User.current.orgs.first.to_s[0..2]
      end
    end

    def _invoke_endpoint(request)
      # Work around Rails 3.2.11 or 3.2.14 issues
       first_data = request[:data] ? request[:data].first : nil
       invoke_endpoint(request[:act], request[:method].underscore, first_data, request[:tid])
     end


    def invoke_endpoint_and_do_nr(batch)
      formatted_url = if batch[:method] == "deliverComponent"
                        "#{batch[:act]}/deliver_#{batch[:data][0][:name]}"
                      else
                        "#{batch[:act]}/#{batch[:method]}"
                      end
      txn_name = if agency.present?
                   "#{agency}/#{formatted_url}"
                 else
                   formatted_url
                 end
      NewRelic::Agent.set_transaction_name txn_name
      _invoke_endpoint batch
    end

    add_transaction_tracer :invoke_endpoint_and_do_nr

  # Action used by non-Ext.Direct (Touch) components
  def dispatcher
    endpoint_dispatch(params[:address])
  end

  # Used in development mode for on-the-fly generation of public/netzke/ext.[js|css]
  def ext
    respond_to do |format|
      format.js {
        render :text => Netzke::Core::DynamicAssets.ext_js(form_authenticity_token)
      }

      format.css {
        render :text => Netzke::Core::DynamicAssets.ext_css
      }
    end
  end

  # Used in development mode for on-the-fly generation of public/netzke/touch.[js|css]
  def touch
    respond_to do |format|
      format.js {
        render :text => Netzke::Core::DynamicAssets.touch_js
      }

      format.css {
        render :text => Netzke::Core::DynamicAssets.touch_css
      }
    end
  end

  protected
    def invoke_endpoint(endpoint_path, action, params, tid) #:nodoc:
      component_name, *sub_components = endpoint_path.split('__')
      components_in_session = Netzke::Core.session[:netzke_components]

      if components_in_session
        component_instance = Netzke::Base.instance_by_config(components_in_session[component_name.to_sym])
        ## Deliver component params resetting for every request ---start
        old_value = nil
        if action == 'deliver_component'
          comp_name = params[:name]
          old_comp_val = component_instance.components[comp_name.to_sym]
          old_value = old_comp_val && old_comp_val.dup
        end
        result = component_instance.invoke_endpoint((sub_components + [action]).join("__"), params)
        if old_value
        	comp_name = params[:name]
          component_instance.components[comp_name.to_sym].clear
		      component_instance.components[comp_name.to_sym].merge! old_value
        end
        ## FIX end
      else
        result = {:component_not_in_session => true}.to_nifty_json
      end

      {
        :type => "rpc",
        :tid => tid,
        :action => component_name,
        :method => action,
        :result => result.present? && result.l || {}
      }.to_json
    end

    # Main dispatcher of old-style (Sencha Touch) HTTP requests. The URL contains the name of the component,
    # as well as the method of this component to be called, according to the double underscore notation.
    # E.g.: some_grid__post_grid_data.
    def endpoint_dispatch(endpoint_path)
      component_name, *sub_components = endpoint_path.split('__')
      component_instance = Netzke::Base.instance_by_config(Netzke::Core.session[:netzke_components][component_name.to_sym])

      # We render text/plain, so that the browser never modifies our response
      response.headers["Content-Type"] = "text/plain; charset=utf-8"

      render :text => component_instance.invoke_endpoint(sub_components.join("__"), params), :layout => false
    end

end

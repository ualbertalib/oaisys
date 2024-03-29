require_dependency 'oaisys/application_controller'

class Oaisys::PMHController < Oaisys::ApplicationController

  skip_before_action :verify_authenticity_token

  SUPPORTED_FORMATS = [
    { metadataPrefix: 'oai_dc',
      schema: 'http://www.openarchives.org/OAI/2.0/oai_dc.xsd',
      metadataNamespace: 'http://www.openarchives.org/OAI/2.0/oai_dc/' },
    { metadataPrefix: 'oai_etdms',
      schema: 'http://www.ndltd.org/standards/metadata/etdms/1-0/etdms.xsd',
      metadataNamespace: 'http://www.ndltd.org/standards/metadata/etdms/1.0/' }
  ].freeze

  def bad_verb
    bad_verb = params.permit(:verb).to_h[:verb]
    raise Oaisys::BadVerbError.new(bad_verb:)
  end

  def identify
    expect_no_args

    render :identify, formats: :xml
  end

  def list_sets
    parameters = expect_args exclusive: [:resumptionToken]

    resumption_token_provided = parameters[:resumptionToken].present?
    parameters[:page] = 1 if parameters[:page].blank?
    sets_model, total_count, cursor = sets_on_page(page: parameters[:page])

    parameters[:item_count] = total_count if parameters[:item_count].nil?

    check_resumption_token(sets_model, resumption_token_provided, total_count, parameters)

    top_level_sets = Oaisys::Engine.config.top_level_sets_model.pluck(:id, :title)
    sets = sets_model.pluck(:community_id, :id, :title, :description)

    sets.map! do |top_level_sets_id, id, title, description|
      top_level_set = top_level_sets.find { |a| a[0] == top_level_sets_id }[1]
      full_set_id = "#{top_level_sets_id}:#{id}"
      full_set_name = "#{top_level_set} / #{title}"
      [full_set_id, full_set_name, description]
    end
    resumption_token = resumption_token_from_params(parameters:)
    parameters = parameters.slice(:verb, :resumptionToken) if resumption_token_provided

    render :list_sets, formats: :xml, locals: { sets:, parameters: parameters.except(:page, :item_count),
                                                cursor:, complete_list_size: total_count,
                                                resumption_token:, last_page: sets_model.last_page?,
                                                resumption_token_provided: }
  end

  def list_metadata_formats
    parameters = expect_args optional: [:identifier]

    if parameters[:identifier].blank?
      formats = SUPPORTED_FORMATS
    else
      # Assumption here that an object cannot be both an item and thesis.
      identifier_format = if Thesis.find_by(id: params[:identifier]).present?
                            'oai_etdms'
                          elsif Item.find_by(id: params[:identifier]).present?
                            'oai_dc'
                          end

      raise Oaisys::IdDoesNotExistError.new(parameters:) if identifier_format.nil?

      formats = SUPPORTED_FORMATS.select { |supported_format| supported_format[:metadataPrefix] == identifier_format }
      raise Oaisys::NoMetadataFormatsError.new(parameters:) if formats.empty?
    end

    render :list_metadata_formats,
           formats: :xml, locals: { formats:, parameters: prep_identifiers(parameters) }
  end

  def list_records
    params = expect_args required: [:metadataPrefix], optional: [:from, :until, :set],
                         exclusive: [:resumptionToken]

    # Note the order here is critical: check whether or not we retrieved a page based on a resumption token
    # haven't been handed to the API, and if we were not, start the results on page 1
    resumption_token_provided = params[:page].present?
    params[:page] = 1 if params[:page].blank?

    query_params = query_params_from_api_params(params)

    items, total_count, cursor = public_items_for_metadata_format(**query_params)

    # If the model is nil there was a bad argument; Otherwise, if blank, no items were returned.
    raise Oaisys::BadArgumentError.new(parameters: params.slice(:verb)) if items.nil?

    params[:item_count] = total_count if params[:item_count].nil?

    raise Oaisys::NoRecordsMatchError.new(parameters: params.slice(:verb, :metadataPrefix)) if items.blank?

    check_resumption_token(items, resumption_token_provided, total_count, params)

    resumption_token = resumption_token_from_params(parameters: params)
    metadata_format = params[:metadataPrefix]
    params = params.slice(:verb, :resumptionToken) if resumption_token_provided

    render :list_records,
           formats: :xml, locals: { items:, parameters: params.except(:page, :item_count),
                                    metadata_format:,
                                    cursor:, complete_list_size: total_count,
                                    resumption_token:, last_page: items.last_page?,
                                    resumption_token_provided: }
  end

  # get_record is referring to the verb, not a getter.
  # rubocop:disable Naming/AccessorMethodName
  def get_record
    params = expect_args required: [:identifier, :metadataPrefix]

    metadata_format = params[:metadataPrefix]
    model = model_for_verb_format(verb: :get_record, format: metadata_format)
    obj = model.find_by(id: params[:identifier])

    raise Oaisys::IdDoesNotExistError.new(parameters: params) if obj.blank?

    render :get_record, formats: :xml, locals: { item: obj, parameters: prep_identifiers(params) }
  end
  # rubocop:enable Naming/AccessorMethodName

  def list_identifiers
    params = expect_args required: [:metadataPrefix], optional: [:from, :until, :set],
                         exclusive: [:resumptionToken]

    # Note the order here is critical: check whether or not we retrieved a page based on a resumption token
    # haven't been handed to the API, and if we were not, start the results on page 1
    resumption_token_provided = params[:page].present?
    params[:page] = 1 if params[:page].blank?

    query_params = query_params_from_api_params(params)

    identifiers_model, total_count, cursor = public_items_for_metadata_format(**query_params)

    # If the model is nil there was a bad argument; Otherwise, if blank, no items were returned.
    raise Oaisys::BadArgumentError.new(parameters: params.slice(:verb)) if identifiers_model.nil?

    identifiers = identifiers_model.pluck(:id, :updated_at, :member_of_paths)
    params[:item_count] = total_count if params[:item_count].nil?

    raise Oaisys::NoRecordsMatchError.new(parameters: params.slice(:verb, :metadataPrefix)) if identifiers.blank?

    check_resumption_token(identifiers_model, resumption_token_provided, total_count, params)

    resumption_token = resumption_token_from_params(parameters: params)
    params = params.slice(:verb, :resumptionToken) if resumption_token_provided
    render :list_identifiers,
           formats: :xml, locals: { identifiers:, parameters: params.except(:page, :item_count),
                                    cursor:, complete_list_size: total_count,
                                    resumption_token:, last_page: identifiers_model.last_page?,
                                    resumption_token_provided: }
  end

  private

  # Convention for calling expect_args without any arguments.
  def expect_no_args
    expect_args
  end

  def expect_args(required: [], optional: [], exclusive: [])
    params[:identifier]&.slice! 'oai:era.library.ualberta.ca:' if params.present?

    # This makes the strong assumption that there's only one exclusive param per verb (which is the resumption token.)
    if params.key?(exclusive.first)
      params.require([:verb])
      parameters = params_from_resumption_token(resumption_token: params[exclusive.first], verb: params[:verb])

      # Token doesn't exist in Redis.
      raise Oaisys::BadResumptionTokenError.new, I18n.t('error_messages.resumption_token_invalid') if parameters.nil?

      arguments = parameters.keys
      expected_verb_arguments = [:page, :item_count] + required + optional + exclusive
      unexpected_arguments = (arguments - expected_verb_arguments).present?
      missing_required_arguments = (required - arguments).present?
      parameters[:item_count] = parameters[:item_count].to_i
      parameters[:page] = parameters[:page].to_i
      parameters[:resumptionToken] = parameters[:page].to_i
      if unexpected_arguments || missing_required_arguments || parameters[:page] < 2
        raise Oaisys::BadResumptionTokenError.new, I18n.t('error_messages.resumption_token_invalid')
      end

      parameters.merge(verb: params[:verb], resumptionToken: params[:resumptionToken])
    else
      params.require([:verb] + required)
      arguments = params.except('verb', 'controller', 'action', 'subdomain').keys.map(&:to_sym)
      expected_verb_arguments = required + optional
      unexpected_arguments = (arguments - expected_verb_arguments).present?
      missing_required_arguments = (required - arguments).present?
      parameters = params.permit([:verb, :subdomain] + required + optional).except(:subdomain).to_h

      return parameters unless unexpected_arguments || missing_required_arguments

      raise Oaisys::BadArgumentError.new(parameters: parameters.slice(:verb))
    end
  end

  def model_for_verb_format(verb:, format:)
    model = ActsAsRdfable.known_classes_for(format:).first
    raise Oaisys::CannotDisseminateError.new(parameters: { verb:, metadataPrefix: format }) if model.blank?

    model
  end

  def query_params_from_api_params(params)
    {}.tap do |query_params|
      query_params[:verb] = params[:verb]
      query_params[:format] = params[:metadataPrefix]
      query_params[:page] = params[:page]
      query_params[:restricted_to_set] = params[:set] if params[:set].present?
      query_params[:from_date] = params[:from] if params[:from].present?
      query_params[:until_date] = params[:until] if params[:until].present?
    end
  end

  def public_items_for_metadata_format(verb:, format:, page:, restricted_to_set: nil, from_date: nil, until_date: nil)
    model = model_for_verb_format(verb:, format:)
    model = model.public_items
    model = model.public_items.belongs_to_path(restricted_to_set.tr(':', '/')) if restricted_to_set.present?

    model = handle_from_and_until_dates(model, from_date, until_date)
    items_per_request = Oaisys::Engine.config.items_per_request
    model = model&.page(page)&.per(items_per_request)
    cursor = (page - 1) * items_per_request
    [model, model&.total_count, cursor]
  end

  def sets_on_page(page:)
    items_per_request = Oaisys::Engine.config.items_per_request
    model = Oaisys::Engine.config.set_model

    model = model.page(page).per(items_per_request)
    cursor = (page - 1) * items_per_request
    [model, model.total_count, cursor]
  end

  def expire_token(resumption_token:, verb:)
    Oaisys::Engine.config.redis.expire_token(resumption_token:, verb:, identifier: user_agent)
  end

  def resumption_token_from_params(parameters:)
    parameters[:page] = parameters[:page] + 1
    Oaisys::Engine.config.redis.create_token(parameters: parameters.except(:verb, :resumptionToken),
                                             verb: parameters[:verb], identifier: user_agent)
  end

  def params_from_resumption_token(resumption_token:, verb:)
    Oaisys::Engine.config.redis.get_parameters(resumption_token:, verb:, identifier: user_agent)
  end

  def user_agent
    user_agent = request.user_agent

    return request.remote_ip if user_agent.blank?

    user_agent
  end

  def check_resumption_token(model, resumption_token_provided, total_count, parameters)
    if model.out_of_range? && resumption_token_provided
      raise Oaisys::BadResumptionTokenError.new, I18n.t('error_messages.resumption_token_invalid')
    end

    return unless resumption_token_provided && (parameters[:item_count] != total_count)

    # Results have changed, expire token
    expire_token(resumption_token: parameters[:resumptionToken], verb: parameters[:verb])
    raise Oaisys::BadResumptionTokenError.new, I18n.t('error_messages.resumption_token_invalid')
  end

  def prep_identifiers(parameters)
    parameters['identifier'].prepend('oai:era.library.ualberta.ca:') if parameters['identifier'].present?
    parameters
  end

  # Returning nil gives a bad argument error.
  def handle_from_and_until_dates(model, from_date, until_date)
    if from_date.present?
      from_date_format = get_date_format(from_date)

      case from_date_format
      when :full_date_with_time
        model = model.updated_on_or_after(from_date)
      when :full_date
        model = model.updated_on_or_after(DateTime.strptime(from_date, '%Y-%m-%d'))
      else
        return nil
      end
    end

    if until_date.present?
      until_date_format = get_date_format(until_date)

      case until_date_format
      when :full_date_with_time
        just_after_until_date = (until_date.to_time + 1.second).utc.xmlschema
        model = model.updated_before(just_after_until_date)
        return nil if from_date.present? && from_date_format != :full_date_with_time
      when :full_date
        model = model.updated_before(DateTime.strptime(until_date, '%Y-%m-%d') + 1.day)
        return nil if from_date.present? && from_date_format != :full_date
      else
        return nil
      end
    end

    model
  end

  def get_date_format(date)
    # YYYY-MM-DDThh:mm:ssZ
    if date.match?('\b[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\b')
      :full_date_with_time
    # YYYY-MM-DD
    elsif date.match?('\b[0-9]{4}-[0-9]{2}-[0-9]{2}\b')
      :full_date
    else
      :unknown
    end
  end

end

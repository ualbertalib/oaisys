xml << render(partial: 'responses/error', locals: { oai_pmh_header: @oai_pmh_header, verb: @verb, error_code: @error_code, error_message: @error_message })
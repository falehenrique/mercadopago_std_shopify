require 'rubygems'
require 'bundler/setup'
require 'sinatra'
require 'httparty'
require 'json'
require 'addressable/uri'
require 'mercadopago' 
require 'pp'


class MercadoPagoStd < Sinatra::Base

  set :bind, '0.0.0.0'
  
    
  ACTION = {'approved'=>'completed', 
            'pending' => 'pending', 
            'in_process' => 'pending', 
            'rejected' => 'failed'}
  
  

  def initialize(base_path: '')
    @base_path = base_path
    @key = 'GEO8BxYT5ifSOp9Y3ys7wGiwXcNu8h0O'
    
    
    
    super
  end

  def fields
    @fields ||= request.params.select {|k, v| k.start_with? 'x_'}
  end

  def sign(fields, key=@key)
    Digest::HMAC.hexdigest(fields.sort.join, key, Digest::SHA256)
  end
  
  
  def get_owner_id(client_id)
    owner = HTTParty.get('https://api.mercadolibre.com/applications/'+client_id.to_s) 
    if owner.code.to_i === 200
      owner_id = owner['owner_id']
    end
    owner_id
  end

  def get_secret_key(owner_id, client_id)
    url_internal = 'https://internal.mercadolibre.com/applications/'+client_id.to_s+"?caller.id=" + owner_id.to_s + "&caller.status=ACTIVE&caller.scopes=crud_app"
    puts "====url====" + url_internal

    response_secret_key = HTTParty.get(url_internal)  

    puts "====response_secret_key====" + response_secret_key.to_s    

    if response_secret_key.code.to_i === 200
      secret_key = response_secret_key['secret_key']
    end
   
    secret_key
  end
  
  
   
  get '/' do
    "Mercado Pago Teste STD Checkout"
  end

  post '/' do
    
    client_id     = fields['x_account_id']
    client_secret = get_secret_key(get_owner_id(client_id), client_id)
    
    MercadoPago::Settings.CLIENT_ID     = client_id
    MercadoPago::Settings.CLIENT_SECRET = client_secret
    
    
    p "-------------------------------------------------------"
    p "Params #{request.params}"
    p "Host #{request.host}"
    
    preference = MercadoPago::Preference.new
    preference.external_reference = fields['x_reference']
    preference.auto_return = 'all'
    preference.notification_url = "?x_account_id=#{fields['x_account_id']}&"
    preference.back_urls = {
        success: "#{request.host}/callback",
        pending: "#{request.host}/callback",
        failure: "#{request.host}/callback"
    }
    preference.additional_info = {
        x_account_id: fields['x_account_id'],
        x_reference: fields['x_reference'],
        x_currency: fields['x_currency'],
        x_test: fields['x_test'],
        x_amount: fields['x_amount'],
        x_url_complete: fields['x_url_complete']
      }  
    
    item = MercadoPago::Item.new({
      title: fields['x_description'],
      quantity: 1,
      unit_price: fields['x_amount'].to_f
    })
    
    payer = MercadoPago::Payer.new({
        name: fields['x_customer_first_name'],
        surname: fields['x_customer_last_name'],
        email: fields['x_customer_email']
    })
        
    preference.items = [item]
    preference.payer = payer
 
    pp preference.to_json
    
 
    preference.save 
    
    redirect preference.init_point
  end


  get '/callback' do 
    

    MercadoPago::Preference.load(params[:preference_id]) do |preference|
      preference = preference
    end 
    
    MercadoPago::Payment.load(params[:collection_id]) do |collection|
      pp collection
    end
    
    
    
    additional_info = eval(preference.additional_info)

    ts = Time.now.utc.iso8601

    result = {timestamp: ts}
     
    payload = {
      'x_account_id'        => additional_info['x_account_id'],
      'x_reference'         => additional_info['x_reference'],
      'x_currency'          => additional_info['x_currency'],
      'x_test'              => additional_info['x_test'],
      'x_amount'            => additional_info['x_amount'],
      'x_result'            => (ACTION[params[:collection_status]] || 'failed'),
      'x_gateway_reference' => SecureRandom.hex,
      'x_timestamp'         => ts
    }

    payload[:x_signature] = sign(payload)

    redirect_url = Addressable::URI.parse(additional_info[:x_url_complete])
    redirect_url.query_values = payload 
    
    case params[:collection_status]
    when 'approved' || 'rejected'
      response = HTTParty.post(additional_info[:x_url_complete], body: payload)
      redirect redirect_url     if response.code == 200
      result[:error] = response unless response.code == 200 
    when 'pending' || 'in_process'
      
    end


  end
  
  get '/ipn' do
    
    
    
    client_id     = params[:x_account_id]
    client_secret = get_secret_key(get_owner_id(client_id), client_id)
    
    MercadoPago::Settings.CLIENT_ID     = client_id
    MercadoPago::Settings.CLIENT_SECRET = client_secret
    
    path, query   = env['REQUEST_PATH'], env['QUERY_STRING'] 
    params = query.split('&').map{|q| {q.split('=')[0].to_sym => q.split('=')[1]}}.reduce Hash.new, :merge
    
    notification = MercadoPago::Notification.new(params)  
    
    merchant_order = nil
      
    begin
      if params[:topic] == "payment"
        MercadoPago::Payment.load(params[:id]) do |payment|
        MercadoPago::MerchantOrder.load(payment.collection["merchant_order_id"]) do |mo|
          merchant_order= mo;
        end
        
      elsif params[:topic] == "merchant_order" 
        MercadoPago::MerchantOrder.load(params[:id]) do |mo|
          merchant_order= mo;
        end
      end
       
      paid_amount = 0
      
      paid_amount = merchant_order.payments.map{ |payment| payment.status == 'approved' ? payment.transaction_amount : 0}.reduce(:+) 
      
      MercadoPago::MerchantOrder.load(payment.collection["merchant_order_id"]) do |merchant_order|
        
      if paid_amount >= merchant_order.total_amount
        # If a payments is completed
        MercadoPago::Preference.load(merchant_order.preference_id) do |preference|
          additional_info = eval(preference.additional_info)
          
          ts = Time.now.utc.iso8601
           
          payload = {
            'x_account_id'        => additional_info['x_account_id'],
            'x_reference'         => additional_info['x_reference'],
            'x_currency'          => additional_info['x_currency'],
            'x_test'              => additional_info['x_test'],
            'x_amount'            => additional_info['x_amount'],
            'x_result'            => (ACTION[params[:collection_status]] || 'failed'),
            'x_gateway_reference' => SecureRandom.hex,
            'x_timestamp'         => ts
          }
          
          redirect_url = Addressable::URI.parse(additional_info[:x_url_complete])
          redirect_url.query_values = payload 
           
          response = HTTParty.post(additional_info[:x_url_complete], body: payload)
          redirect redirect_url     if response.code == 200
          result[:error] = response unless response.code == 200 
          
          
          
          
        end 
      end 
         
    rescue
      # if the merchant order doesnt exist
    end

    
  end
  
  def process_merchant_order      
#https://checkout.shopify.com/13322039/checkouts/57fd979109c66f4cc84cb57bf9798e17/offsite_gateway_callback?x_account_id=5065100305679755&x_amount=147.99&x_currency=BRL&x_gateway_reference=1b25e778575c6e768bab4141fc0651e7&x_reference=7737824131&x_result=completed&x_signature=e2b8f45b27e0966cf2e9f20f7a235e6b93666ff51606ae59ede7653f62e0b2ce&x_test=false&x_timestamp=2016-06-07T15%3A26%3A11Z
  end

  get '/new_payload' do
    x_url_complete = "https://checkout.shopify.com/13084163/checkouts/857771d326e49c2b3e512c93835a7576/offsite_gateway_callback"

    ts = Time.now.utc.iso8601

    result = {timestamp: ts}

    payload = {
      'x_account_id'        => "5065100305679755",
      'x_reference'         => "7987082118",
      'x_currency'          => "BRL",
      'x_test'              => "false",
      'x_amount'            => "76.50",
      'x_result'            => "completed",
      'x_gateway_reference' => SecureRandom.hex,
      'x_timestamp'         => ts
    }

    payload['x_signature'] = sign(payload)

    response = HTTParty.post(x_url_complete, body: payload)
    
    

  end

  run! if app_file == $0

end

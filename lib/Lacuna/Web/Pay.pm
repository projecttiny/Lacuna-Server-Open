package Lacuna::Web::Pay;

use Moose;
use utf8;
no warnings qw(uninitialized);
extends qw(Lacuna::Web);
use Digest::MD5 qw(md5_hex);
use Digest::HMAC_SHA1;
use XML::Hash::LX;
use Tie::IxHash;
use LWP::UserAgent;

sub calculate_jambool_signature {
    my ($self, $params, $secret) = @_;
    my $message;
    foreach my $key (sort keys %{$params}) {
        $message .= $key.$params->{$key};
    }
    $message .= $secret;
    return md5_hex($message);
}

sub jambool_buy_url {
    my ($self, $user_id) = @_;
    my $config = Lacuna->config->get('jambool');
    my %params = (
        ts          => time(),
        offer_id    => $config->{offer_id},
        user_id     => $user_id,
        action      => 'buy_currency',
    );
    $params{sig} = $self->calculate_jambool_signature(\%params, $config->{secret_key});
    delete $params{offer_id};
    delete $params{user_id};
    my $url = sprintf '%s/socialgold/v1/%s/%s/buy_currency?format=iframe', $config->{api_url}, $config->{offer_id}, $user_id;
    foreach my $key (sort keys %params) {
        $url .= sprintf '&%s=%s', $key, $params{$key};
    }
    return $url;
}

sub www_jambool_success {
    my ($self, $request) = @_;
    my $script = "
     try {
      window.opener.YAHOO.lacuna.Essentia.paymentFinished();
      window.setTimeout( function () { window.close() }, 5000);
      } catch (e) {}
    ";
    return $self->wrap('Thank you! The essentia will be added to your account momentarily.<script type="text/javascript">'.$script.'</script>');
}

sub www_jambool_error {
    my ($self, $request) = @_;
    return $self->format_error('Shucks! Something went wrong and we could not process your payment. Please try again in a few minutes.');
}

sub www_jambool_postback {
    my ($self, $request) = @_;

    # validate signature
    my $signature = $self->calculate_jambool_signature({timestamp => $request->param('timestamp')}, Lacuna->config->get('jambool/secret_key'));
    unless ($request->param('signature') eq $signature) {
        return ['Invalid Signature', { status => 400 }];
    }

    # get user account
    my $empire_id = $request->param('user_id');
    unless ($empire_id) {
        return ['Not a valid user_id.', { status => 401 }];
    }
    my $empire = Lacuna->db->resultset('Lacuna::DB::Result::Empire')->find($empire_id);
    unless (defined $empire) {
        return ['Emire not found.', { status => 404 }];
    }
    
    # make sure we haven't already processed this transaction
    my $transaction_id = $request->param('socialgold_transaction_id');
    unless ($empire_id) {
        return ['Not a valid socialgold_transaction_id.', { status => 402 }];
    }
    my $transaction = Lacuna->db->resultset('Lacuna::DB::Result::Log::Essentia')->search(
        { transaction_id => $transaction_id },
        { rows => 1 }
    )->single;
    if (defined $transaction) {
        return ['Already processed this transaction.', { status => 200 }];
    }
    
    # add essentia and alert user
    my $amount = $request->param('premium_currency_amount') / 100;
    $empire->add_essentia(
        $amount,
        'Purchased via Social Gold',
        $transaction_id,
    )->update;
    $empire->send_predefined_message(
        tags        => ['Alert'],
        filename    => 'purchase_essentia.txt',
        params      => [$amount, $transaction_id],        
    );
        
    return ['OK'];
}

sub www_jambool_reversal {
    my ($self, $request) = @_;

    # validate signature
    my $signature = $self->calculate_jambool_signature({
            timestamp                   => $request->param('timestamp'),
            amount                      => $request->param('amount'),
            socialgold_transaction_id   => $request->param('socialgold_transaction_id'),
        },
        Lacuna->config->get('jambool/secret_key')
    );
    unless ($request->param('signature') eq $signature) {
        return ['Invalid Signature', { status => 400 }];
    }

    # get user account
    my $empire_id = $request->param('user_id');
    unless ($empire_id) {
        return ['Not a valid user_id.', { status => 401 }];
    }
    my $empire = Lacuna->db->resultset('Lacuna::DB::Result::Empire')->find($empire_id);
    unless (defined $empire) {
        return ['Emire not found.', { status => 404 }];
    }
    
    # make sure we already gave them essentia
    my $transaction_id = $request->param('socialgold_transaction_id');
    unless ($empire_id) {
        return ['Not a valid socialgold_transaction_id.', { status => 402 }];
    }
    my $transaction = Lacuna->db->resultset('Lacuna::DB::Result::Log::Essentia')->search(
        {
            transaction_id  => $transaction_id,
        },
        { rows => 1 }
    )->single;
    unless (defined $transaction) {
        return ['No record of this transaction.', { status => 402 }];
    }
    
    # reverse the transaction
    my $amount = $transaction->amount;
    $empire->add_essentia(
        $amount,
        'Reversed via Social Gold',
        $transaction_id,
    );

        
    return ['OK'];
}

sub www_default {
    my ($self, $request) = @_;
    my $session = $self->get_session($request->param('session_id'));
    unless (defined $session) {
        confess [ 401, 'You must be logged in to purchase essentia.'];
    }
    if ($session->is_sitter) {
        confess [ 401, 'Sitters cannot purchase essentia.'];
    }
    my $empire = $session->empire;
    unless (defined $empire) {
        confess [401, 'Empire not found.'];
    }
    return $self->wrap('<div style="margin: 0 auto;width: 425;"><iframe frameborder="0" scrolling="no" width="425" height="365" src="'.$self->itransact_buy_url($empire->id).'></iframe></div>');
    #return $self->wrap('<div style="margin: 0 auto;width: 425;"><iframe frameborder="0" scrolling="no" width="425" height="365" src="'.$self->jambool_buy_url($empire->id).'"></iframe></div>');
}

sub wrap {
    my ($self, $content) = @_;
    return $self->wrapper($content, { title => 'Purchase Essentia', logo => 1 });
}

sub itransact_buy_url {
    my ($self, $user_id) = @_;
    return '/pay/buy/currency?user_id='.$user_id;
}

sub www_buy_currency_cc {
    my ($self, $request) = @_;
    confess [1009, 'Card number is required.'] unless $request->param('card_number');
    confess [1009, 'Expiration month is required and must be 2 digits.'] unless ($request->param('expiration_month') && length($request->param('expiration_month')) == 2);
    confess [1009, 'Expiration year is required and must be 4 digits.'] unless ($request->param('expiration_year') && length($request->param('expiration_year')) == 4);
    confess [1009, 'CVV2 is required and must be 3 or 4 digits.'] unless ($request->param('cvv2') && length($request->param('cvv2')) >= 3 && length($request->param('cvv2')) <= 4);
    my $config = Lacuna->config->get('itransact');
    my @name = split /\s+/, $request->param('name');
    my %payload;
    tie %payload, 'Tie::IxHash';
    %payload = (
        AuthTransaction => {
            CustomerData    => {
                Email           => $request->param('email'),
                BillingAddress  => {
                    Address1        => $request->param('address1'),
                    FirstName       => shift @name,
                    LastName        => join(' ', @name),
                    City            => $request->param('city'),
                    State           => $request->param('state'),
                    Zip             => $request->param('postal_code'),
                    Country         => $request->param('country'),
                    Phone           => $request->param('phone_number'),
                },
                CustId          => $request->param('user_id'),
            },
            Total               => $request->param('total'),
            Description         => 'Essentia Order',
            AccountInfo         => {
                CardAccount => {
                    AccountNumber   => $request->param('card_number'),
                    ExpirationMonth => $request->param('expiration_month'),
                    ExpirationYear  => $request->param('expiration_year'),
                    CVVNumber       => $request->param('cvv2'),
                },
            },
            TransactionControl  => {
                SendCustomerEmail   => $config->{SendCustomerEmail},
                SendMerchantEmail   => $config->{SendMerchantEmail},
                TestMode            => $config->{TestMode},
            },
        },
    );
    $payload{AuthTransaction}{CustomerData}{BillingAddress}{Address2} = $request->param('address2') if ( $request->param('address2') );
    my $xml = hash2xml \%payload;
    $xml = (split(/\n/, $xml))[1]; # strip the <xml> tag before calculating the PayloadSignature
    my $hmac = Digest::HMAC_SHA1->new($config->{APIKey});
    $hmac->add($xml);
    my %xml = (
        GatewayInterface    => {
            APICredentials  => {
                Username            => $config->{APIUsername},
                TargetGateway       => $config->{OrderFormUID}, #$config->{Gateway},
                PayloadSignature    => $hmac->b64digest . '=',
            },
            %payload,
        }
    );
    $xml = hash2xml \%xml;
    my $response = LWP::UserAgent->new->post(
        'https://secure.itransact.com/cgi-bin/rc/xmltrans2.cgi',
        Content_Type    => 'text/xml',
        Content         => $xml,
        Accept          => 'text/xml',
    );
    if ($response->is_success) {
        my $result = xml2hash $response->decoded_content;
        $result = $result->{GatewayInterface}{TransactionResponse}{TransactionResult};
        if($result->{Status} eq 'ok') {
            # get user account
            my $empire_id = $request->param('user_id');
            unless ($empire_id) {
                return ['Not a valid user_id.', { status => 401 }];
            }
            my $empire = Lacuna->db->resultset('Lacuna::DB::Result::Empire')->find($empire_id);
            unless (defined $empire) {
                return ['Empire not found.', { status => 404 }];
            }
            
            # make sure we haven't already processed this transaction
            my $transaction_id = $result->{AuthCode};
            unless ($transaction_id) {
                return ['Not a valid iTransact AuthCode.', { status => 402 }];
            }
            my $transaction = Lacuna->db->resultset('Lacuna::DB::Result::Log::Essentia')->search(
                { transaction_id => $transaction_id },
                { rows => 1 }
            )->single;
            if (defined $transaction) {
                return ['Already processed this transaction.', { status => 200 }];
            }
            
            # add essentia and alert user
            my $amount = $request->param('premium_currency_amount');
            $empire->add_essentia(
                $amount,
                'Purchased via iTransact',
                $transaction_id,
            )->update;
            $empire->send_predefined_message(
                tags        => ['Alert'],
                filename    => 'purchase_essentia.txt',
                params      => [$amount, $transaction_id],        
            );
                
            return ['OK'];
        }
        else {
            confess [1009, 'Card was rejected: '.$result->{XID}];
            
        }
    }
    else {
        confess [1009, 'Could not connect to the credit card processor.'];
    }
}

sub www_buy_currency {
    my ($self, $request) = @_;
    my $user_id = $request->param('user_id');
    my $content = <<EoHTML;
        <script type="text/javascript">
            function update_currency(el) {
                var text = el.options[el.selectedIndex].text;
                var value = text.split(" ");
                var newvalue = value[0];
                var currency = document.getElementByID("premium_currency_amount");
                currency.value = newvalue;
            }
        </script>
        <style>
            label {
                font-weight: bold;
                display: block;
                width: 150px;
                float: left;
            }
            label:after { content: ": " }
            fieldset {
                width: 400px;
                padding: 3px;
                margin-left: auto;
                margin-right: auto;
            }
            fieldset legend {
                padding: 6px;
                font-weight: bold;
            }
            h2 {
                width: 400px;
                padding: 3px;
                margin-left: auto;
                margin-right: auto;
            }
            div#buynow {
                width: 80px;
                padding: 3px;
                margin-left: auto;
                margin-right: auto;

            }
        </style>
        <h2>Get More Essentia</h2>
        <form action="/pay/buy/currency/cc" id="cc_form">
            <div>
                <input type="hidden" name="user_id" id="user_id" value="$user_id">
                <input type="hidden" name="premium_currency_amount" id="premium_currency_amount" value="30">
                <fieldset>
                    <legend>Get More Essentia</legend>
                    <label for="total">Buy</label>
                    <select name="total" id="total" onchange="update_currency(this)">
                        <option value='2.99'>30 Essentia for \$2.99</option>
                        <option value='5.99'>100 Essentia for \$5.99</option>
                        <option value='9.99'>200 Essentia for \$9.99</option>
                        <option value='24.99' default>600 Essentia for \$24.99</option>
                        <option value='49.95'>1300 Essentia for \$49.95</option>
                    </select>
                </fieldset>
                <fieldset id="personal">
                <legend>Personal Information</legend>
                    <label for="name">Name</label><input name="name" id="name" type="text" size="18">
                    <label for="address1">Address1</label><input name="address1" id="address1" size="18">
                    <label for="address2">Address2</label><input name="address2" id="address2" size="18">
                    <label for="city">City</label><input name="city" id="city" size="18">
                    <label for="state">State</label><input name="state" id="state" size="18">
                    <label for="postal_code">Postal/zip code</label><input name="postal_code" id="postal_code" size="18">
                    <label for="country">Country</label>
                        <select id="country" name="country"><option value="US" selected="selected">UNITED STATES</option> 
                            <option value="AL">ALBANIA</option> 
                            <option value="DZ">ALGERIA</option> 
                            <option value="AS">AMERICAN SAMOA</option> 
                            <option value="AD">ANDORRA</option> 
                            <option value="AO">ANGOLA</option> 
                            <option value="AI">ANGUILLA</option> 
                            <option value="AQ">ANTARCTICA</option> 
                            <option value="AG">ANTIGUA AND BARBUDA</option> 
                            <option value="AR">ARGENTINA</option> 
                            <option value="AM">ARMENIA</option> 
                            <option value="AW">ARUBA</option> 
                            <option value="AU">AUSTRALIA</option> 
                            <option value="AT">AUSTRIA</option> 
                            <option value="AZ">AZERBAIJAN</option> 
                            <option value="BS">BAHAMAS</option> 
                            <option value="BH">BAHRAIN</option> 
                            <option value="BD">BANGLADESH</option> 
                            <option value="BB">BARBADOS</option> 
                            <option value="BY">BELARUS</option> 
                            <option value="BE">BELGIUM</option> 
                            <option value="BZ">BELIZE</option> 
                            <option value="BJ">BENIN</option> 
                            <option value="BM">BERMUDA</option> 
                            <option value="BT">BHUTAN</option> 
                            <option value="BO">BOLIVIA</option> 
                            <option value="BA">BOSNIA AND HERZEGOWINA</option> 
                            <option value="BW">BOTSWANA</option> 
                            <option value="BV">BOUVET ISLAND</option> 
                            <option value="BR">BRAZIL</option> 
                            <option value="IO">BRITISH INDIAN OCEAN TERRITORY</option> 
                            <option value="BN">BRUNEI DARUSSALAM</option> 
                            <option value="BG">BULGARIA</option> 
                            <option value="BF">BURKINA FASO</option> 
                            <option value="BI">BURUNDI</option> 
                            <option value="KH">CAMBODIA</option> 
                            <option value="CM">CAMEROON</option> 
                            <option value="CA">CANADA</option> 
                            <option value="CV">CAPE VERDE</option> 
                            <option value="KY">CAYMAN ISLANDS</option> 
                            <option value="CF">CENTRAL AFRICAN REPUBLIC</option> 
                            <option value="TD">CHAD</option> 
                            <option value="CL">CHILE</option> 
                            <option value="CN">CHINA</option> 
                            <option value="CX">CHRISTMAS ISLAND</option> 
                            <option value="CC">COCOS (KEELING) ISLANDS</option> 
                            <option value="CO">COLOMBIA</option> 
                            <option value="KM">COMOROS</option> 
                            <option value="CG">CONGO</option> 
                            <option value="CD">CONGO, THE DEMOCRATIC REPUBLIC OF</option> 
                            <option value="CK">COOK ISLANDS</option> 
                            <option value="CR">COSTA RICA</option> 
                            <option value="CI">COTE D'IVOIRE</option> 
                            <option value="HR">CROATIA (HRVATSKA)</option> 
                            <option value="CU">CUBA</option> 
                            <option value="CY">CYPRUS</option> 
                            <option value="CZ">CZECH REPUBLIC</option> 
                            <option value="DK">DENMARK</option> 
                            <option value="DJ">DJIBOUTI</option> 
                            <option value="DM">DOMINICA</option> 
                            <option value="DO">DOMINICAN REPUBLIC</option> 
                            <option value="TP">EAST TIMOR</option> 
                            <option value="EC">ECUADOR</option> 
                            <option value="EG">EGYPT</option> 
                            <option value="SV">EL SALVADOR</option> 
                            <option value="GQ">EQUATORIAL GUINEA</option> 
                            <option value="ER">ERITREA</option> 
                            <option value="EE">ESTONIA</option> 
                            <option value="ET">ETHIOPIA</option> 
                            <option value="FK">FALKLAND ISLANDS (MALVINAS)</option> 
                            <option value="FO">FAROE ISLANDS</option> 
                            <option value="FJ">FIJI</option> 
                            <option value="FI">FINLAND</option> 
                            <option value="FR">FRANCE</option> 
                            <option value="FX">FRANCE, METROPOLITAN</option> 
                            <option value="GF">FRENCH GUIANA</option> 
                            <option value="PF">FRENCH POLYNESIA</option> 
                            <option value="TF">FRENCH SOUTHERN TERRITORIES</option> 
                            <option value="GA">GABON</option> 
                            <option value="GM">GAMBIA</option> 
                            <option value="GE">GEORGIA</option> 
                            <option value="DE">GERMANY</option> 
                            <option value="GH">GHANA</option> 
                            <option value="GI">GIBRALTAR</option> 
                            <option value="GR">GREECE</option> 
                            <option value="GL">GREENLAND</option> 
                            <option value="GD">GRENADA</option> 
                            <option value="GP">GUADELOUPE</option> 
                            <option value="GU">GUAM</option> 
                            <option value="GT">GUATEMALA</option> 
                            <option value="GN">GUINEA</option> 
                            <option value="GW">GUINEA-BISSAU</option> 
                            <option value="GY">GUYANA</option> 
                            <option value="HT">HAITI</option> 
                            <option value="HM">HEARD AND MC DONALD ISLANDS</option> 
                            <option value="VA">HOLY SEE (VATICAN CITY STATE)</option> 
                            <option value="HN">HONDURAS</option> 
                            <option value="HK">HONG KONG</option> 
                            <option value="HU">HUNGARY</option> 
                            <option value="IS">ICELAND</option> 
                            <option value="IN">INDIA</option> 
                            <option value="ID">INDONESIA</option> 
                            <option value="IR">IRAN (ISLAMIC REPUBLIC OF)</option> 
                            <option value="IQ">IRAQ</option> 
                            <option value="IE">IRELAND</option> 
                            <option value="IL">ISRAEL</option> 
                            <option value="IT">ITALY</option> 
                            <option value="JM">JAMAICA</option> 
                            <option value="JP">JAPAN</option> 
                            <option value="JO">JORDAN</option> 
                            <option value="KZ">KAZAKHSTAN</option> 
                            <option value="KE">KENYA</option> 
                            <option value="KI">KIRIBATI</option> 
                            <option value="KR">KOREA, REPUBLIC OF</option> 
                            <option value="KW">KUWAIT</option> 
                            <option value="KG">KYRGYZSTAN</option> 
                            <option value="LA">LAO PEOPLE'S DEMOCRATIC REPUBLIC</option> 
                            <option value="LV">LATVIA</option> 
                            <option value="LB">LEBANON</option> 
                            <option value="LS">LESOTHO</option> 
                            <option value="LR">LIBERIA</option> 
                            <option value="LY">LIBYAN ARAB JAMAHIRIYA</option> 
                            <option value="LI">LIECHTENSTEIN</option> 
                            <option value="LT">LITHUANIA</option> 
                            <option value="LU">LUXEMBOURG</option> 
                            <option value="MO">MACAU</option> 
                            <option value="MK">MACEDONIA</option> 
                            <option value="MG">MADAGASCAR</option> 
                            <option value="MW">MALAWI</option> 
                            <option value="MY">MALAYSIA</option> 
                            <option value="MV">MALDIVES</option> 
                            <option value="ML">MALI</option> 
                            <option value="MT">MALTA</option> 
                            <option value="MH">MARSHALL ISLANDS</option> 
                            <option value="MQ">MARTINIQUE</option> 
                            <option value="MR">MAURITANIA</option> 
                            <option value="MU">MAURITIUS</option> 
                            <option value="YT">MAYOTTE</option> 
                            <option value="MX">MEXICO</option> 
                            <option value="FM">MICRONESIA</option> 
                            <option value="MD">MOLDOVA, REPUBLIC OF</option> 
                            <option value="MC">MONACO</option> 
                            <option value="MN">MONGOLIA</option> 
                            <option value="MS">MONTSERRAT</option> 
                            <option value="MA">MOROCCO</option> 
                            <option value="MZ">MOZAMBIQUE</option> 
                            <option value="MM">MYANMAR</option> 
                            <option value="NA">NAMIBIA</option> 
                            <option value="NR">NAURU</option> 
                            <option value="NP">NEPAL</option> 
                            <option value="NL">NETHERLANDS</option> 
                            <option value="AN">NETHERLANDS ANTILLES</option> 
                            <option value="NC">NEW CALEDONIA</option> 
                            <option value="NZ">NEW ZEALAND</option> 
                            <option value="NI">NICARAGUA</option> 
                            <option value="NE">NIGER</option> 
                            <option value="NG">NIGERIA</option> 
                            <option value="NU">NIUE</option> 
                            <option value="NF">NORFOLK ISLAND</option> 
                            <option value="KP">NORTH KOREA</option> 
                            <option value="MP">NORTHERN MARIANA ISLANDS</option> 
                            <option value="NO">NORWAY</option> 
                            <option value="OM">OMAN</option> 
                            <option value="PK">PAKISTAN</option> 
                            <option value="PW">PALAU</option> 
                            <option value="PA">PANAMA</option> 
                            <option value="PG">PAPUA NEW GUINEA</option> 
                            <option value="PY">PARAGUAY</option> 
                            <option value="PE">PERU</option> 
                            <option value="PH">PHILIPPINES</option> 
                            <option value="PN">PITCAIRN</option> 
                            <option value="PL">POLAND</option> 
                            <option value="PT">PORTUGAL</option> 
                            <option value="PR">PUERTO RICO</option> 
                            <option value="QA">QATAR</option> 
                            <option value="RE">REUNION</option> 
                            <option value="RO">ROMANIA</option> 
                            <option value="RU">RUSSIAN FEDERATION</option> 
                            <option value="RW">RWANDA</option> 
                            <option value="KN">SAINT KITTS AND NEVIS</option> 
                            <option value="LC">SAINT LUCIA</option> 
                            <option value="VC">SAINT VINCENT AND THE GRENADINES</option> 
                            <option value="WS">SAMOA</option> 
                            <option value="SM">SAN MARINO</option> 
                            <option value="ST">SAO TOME AND PRINCIPE</option> 
                            <option value="SA">SAUDI ARABIA</option> 
                            <option value="SN">SENEGAL</option> 
                            <option value="SC">SEYCHELLES</option> 
                            <option value="SL">SIERRA LEONE</option> 
                            <option value="SG">SINGAPORE</option> 
                            <option value="SK">SLOVAKIA (Slovak Republic)</option> 
                            <option value="SI">SLOVENIA</option> 
                            <option value="SB">SOLOMON ISLANDS</option> 
                            <option value="SO">SOMALIA</option> 
                            <option value="ZA">SOUTH AFRICA</option> 
                            <option value="GS">SOUTH GEORGIA</option> 
                            <option value="ES">SPAIN</option> 
                            <option value="LK">SRI LANKA</option> 
                            <option value="SH">ST. HELENA</option> 
                            <option value="PM">ST. PIERRE AND MIQUELON</option> 
                            <option value="SD">SUDAN</option> 
                            <option value="SR">SURINAME</option> 
                            <option value="SJ">SVALBARD AND JAN MAYEN ISLANDS</option> 
                            <option value="SZ">SWAZILAND</option> 
                            <option value="SE">SWEDEN</option> 
                            <option value="CH">SWITZERLAND</option> 
                            <option value="SY">SYRIAN ARAB REPUBLIC</option> 
                            <option value="TW">TAIWAN</option> 
                            <option value="TJ">TAJIKISTAN</option> 
                            <option value="TZ">TANZANIA, UNITED REPUBLIC OF</option> 
                            <option value="TH">THAILAND</option> 
                            <option value="TG">TOGO</option> 
                            <option value="TK">TOKELAU</option> 
                            <option value="TO">TONGA</option> 
                            <option value="TT">TRINIDAD AND TOBAGO</option> 
                            <option value="TN">TUNISIA</option> 
                            <option value="TR">TURKEY</option> 
                            <option value="TM">TURKMENISTAN</option> 
                            <option value="TC">TURKS AND CAICOS ISLANDS</option> 
                            <option value="TV">TUVALU</option> 
                            <option value="UM">U.S. MINOR OUTLYING ISLANDS</option> 
                            <option value="UG">UGANDA</option> 
                            <option value="UA">UKRAINE</option> 
                            <option value="AE">UNITED ARAB EMIRATES</option> 
                            <option value="GB">UNITED KINGDOM</option> 
                            <option value="US" selected="selected">UNITED STATES</option> 
                            <option value="UY">URUGUAY</option> 
                            <option value="UZ">UZBEKISTAN</option> 
                            <option value="VU">VANUATU</option> 
                            <option value="VE">VENEZUELA</option> 
                            <option value="VN">VIET NAM</option> 
                            <option value="VG">VIRGIN ISLANDS (BRITISH)</option> 
                            <option value="VI">VIRGIN ISLANDS (U.S.)</option> 
                            <option value="WF">WALLIS AND FUTUNA ISLANDS</option> 
                            <option value="EH">WESTERN SAHARA</option> 
                            <option value="YE">YEMEN</option> 
                            <option value="ZM">ZAMBIA</option> 
                            <option value="ZW">ZIMBABWE</option>
                        </select> 
                    <label for="email">Email</label><input name="email" id="email" type="text" size="18">
                    <label for="phone_number">Phone number</label><input name="phone_number" id="postal_code" size="18">
                </fieldset>
                <fieldset id="cc">
                    <legend>Credit Card Information</legend>
                    <label for="card_number">Card Number</label>
                    <input name="card_number" id="card_number" type="text" size="18" autocomplete="off">
                    <label for="expiration_month">Expiration</label>
                    <div>
                    <select name="expiration_month" id="expiration_month">
                        <option value=''>mon</option>
                        <option value='1'>1</option>
                        <option value='2'>2</option>
                        <option value='3'>3</option>
                        <option value='4'>4</option>
                        <option value='5'>5</option>
                        <option value='6'>6</option>
                        <option value='7'>7</option>
                        <option value='8'>8</option>
                        <option value='9'>9</option>
                        <option value='10'>10</option>
                        <option value='11'>11</option>
                        <option value='12'>12</option>
                    </select>
                    <select name="expiration_year" id="expiration_year">
                        <option value=''>year</option>
                        <option value='2011'>2011</option>
                        <option value='2012'>2012</option>
                        <option value='2013'>2013</option>
                        <option value='2014'>2014</option>
                        <option value='2015'>2015</option>
                        <option value='2016'>2016</option>
                        <option value='2017'>2017</option>
                        <option value='2018'>2018</option>
                        <option value='2019'>2019</option>
                        <option value='2020'>2020</option>
                        <option value='2021'>2021</option>
                    </select>
                    </div>
                    <label for="cvv2">CVV</label>
                    <input name="cvv2" id="cvv2" type="text" size="3">
                </fieldset>
                <div id="buynow">
                <input type="submit" name="buy_now" id="buy_now" value="Buy Now">
                </div>
        </form>
EoHTML

    return $self->wrap($content);
}

no Moose;
__PACKAGE__->meta->make_immutable(inline_constructor => 0);


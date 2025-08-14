/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

public class CreateAgentStudioConnectedApp {

    private static final String CERTIFICATE_API_NAME = 'AgentStudioJWTSigner';
    private static final String CERTIFICATE_LABEL = 'Agent Studio JWT Signer';
    private static final String CONNECTED_APP_API_NAME = 'AgentStudioInternalAPIAccess';
    private static final String CONNECTED_APP_LABEL = 'Agent Studio Internal API Access';
    private static final String PERMISSION_SET_NAME = 'AI Agent Studio User';
    private static final String EXTERNAL_CREDENTIAL_API_NAME = 'AgentStudioServiceUser';
    private static final String EXTERNAL_CREDENTIAL_LABEL = 'Agent Studio Service User';
    private static final String NAMED_CREDENTIAL_API_NAME = 'AgentStudioInternalAPI';
    private static final String NAMED_CREDENTIAL_LABEL = 'Agent Studio Internal API';

    private static final Integer KEY_SIZE = 2048;
    private static final String METADATA_API_VERSION = '60.0';
    private static final String SOAP_NAMESPACE = 'http://soap.sforce.com/2006/04/metadata';
    private static final String ENVELOPE_NAMESPACE = 'http://schemas.xmlsoap.org/soap/envelope/';

    public class SetupResult {
        public Boolean success { get; set; }
        public String errorMessage { get; set; }
        public String certificateId { get; set; }
        public String consumerKey { get; set; }
        public String externalCredentialId { get; set; }
        public String namedCredentialId { get; set; }
        public List<String> completedSteps { get; set; }

        public SetupResult() {
            this.success = false;
            this.completedSteps = new List<String>();
        }
    }

    public class ComponentConfig {
        public String certificateApiName { get; set; }
        public String connectedAppApiName { get; set; }
        public String permissionSetName { get; set; }

        public ComponentConfig() {
            // Use defaults
            this.certificateApiName = CERTIFICATE_API_NAME;
            this.connectedAppApiName = CONNECTED_APP_API_NAME;
            this.permissionSetName = PERMISSION_SET_NAME;
        }
    }

    public static SetupResult setup() {
        return setup(new ComponentConfig());
    }

    public static SetupResult setup(ComponentConfig config) {
        SetupResult result = new SetupResult();

        try {
            // Validate prerequisites
            validatePrerequisites(config);

            // Step 1: Create Certificate
            result.certificateId = createCertificate(config.certificateApiName);
            result.completedSteps.add('Certificate Created');

            // Step 2: Create Connected App
            result.consumerKey = createConnectedApp(config);
            result.completedSteps.add('Connected App Created');

            // Step 3: Enable Digital Signatures
            enableDigitalSignatures(config.certificateApiName, config.connectedAppApiName);
            result.completedSteps.add('Digital Signatures Enabled');

            // Step 4: Create External Credential
            result.externalCredentialId = createExternalCredential(result.consumerKey, config);
            result.completedSteps.add('External Credential Created');

            // Step 5: Create Named Credential
            result.namedCredentialId = createNamedCredential();
            result.completedSteps.add('Named Credential Created');

            result.success = true;
        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'Setup failed at step ' + (result.completedSteps.size() + 1) + ': ' + e.getMessage();
        }

        return result;
    }

    public static Map<String, Boolean> checkSetupStatus() {
        return new Map<String, Boolean>{
            'certificateExists' => componentExists('Certificate', CERTIFICATE_API_NAME),
            'connectedAppExists' => componentExists('ConnectedApp', CONNECTED_APP_API_NAME),
            'externalCredentialExists' => checkExternalCredentialExists(),
            'namedCredentialExists' => checkNamedCredentialExists()
        };
    }

    private static void validatePrerequisites(ComponentConfig config) {
        // Check if permission set exists
        List<PermissionSet> permSets = [
            SELECT Id
            FROM PermissionSet
            WHERE Label = :config.permissionSetName
            WITH USER_MODE
            LIMIT 1
        ];

        if (permSets.isEmpty()) {
            throw new SetupException('Permission Set "' + config.permissionSetName + '" not found');
        }

        // Check if components already exist
        if (componentExists('Certificate', config.certificateApiName)) {
            throw new SetupException('Certificate already exists: ' + config.certificateApiName);
        }

        if (componentExists('ConnectedApp', config.connectedAppApiName)) {
            throw new SetupException('Connected App already exists: ' + config.connectedAppApiName);
        }

        // Check for existing credentials
        if (checkExternalCredentialExists()) {
            throw new SetupException(
                'External Credential already exists: ' +
                    EXTERNAL_CREDENTIAL_API_NAME +
                    '. Please delete it manually from Setup > Security > Named Credentials > External Credentials'
            );
        }

        if (checkNamedCredentialExists()) {
            throw new SetupException(
                'Named Credential already exists: ' +
                    NAMED_CREDENTIAL_API_NAME +
                    '. Please delete it manually from Setup > Security > Named Credentials'
            );
        }
    }

    private static Boolean componentExists(String metadataType, String fullName) {
        try {
            String response = readMetadata(metadataType, fullName);
            return response.contains('<fullName>' + fullName + '</fullName>');
        } catch (Exception e) {
            return false;
        }
    }

    private static String createCertificate(String certificateName) {
        String certificateLabel = CERTIFICATE_LABEL;
        String expirationYear = String.valueOf(Date.today().year() + 1);

        String requestBody = buildCreateMetadataBody(
            'Certificate',
            new Map<String, String>{
                'fullName' => certificateName,
                'caSigned' => 'false',
                'encryptedWithPlatformEncryption' => 'false',
                'expirationDate' => expirationYear + '-08-09T12:00:00.000Z',
                'keySize' => String.valueOf(KEY_SIZE),
                'masterLabel' => certificateLabel,
                'privateKeyExportable' => 'true'
            }
        );

        String response = executeMetadataApiCall('createMetadata', requestBody);

        if (!isSuccessResponse(response)) {
            throw new SetupException('Certificate creation failed: ' + extractErrorMessage(response));
        }

        return certificateName;
    }

    private static String createConnectedApp(ComponentConfig config) {
        String consumerKey = generateConsumerKey();
        String callbackUrl = getEnvironmentUrl('/services/oauth2/callback');

        Map<String, String> connectedAppFields = new Map<String, String>{
            'fullName' => config.connectedAppApiName,
            'label' => CONNECTED_APP_LABEL,
            'contactEmail' => UserInfo.getUserEmail()
        };

        // Build OAuth config
        String oauthConfig = buildOAuthConfig(config.certificateApiName, consumerKey, callbackUrl);

        // Build complete request
        String requestBody = buildConnectedAppCreateRequest(connectedAppFields, oauthConfig, config.permissionSetName);

        String response = executeMetadataApiCall('createMetadata', requestBody);

        if (!isSuccessResponse(response)) {
            throw new SetupException('Connected App creation failed: ' + extractErrorMessage(response));
        }

        return consumerKey;
    }

    private static void enableDigitalSignatures(String certificateName, String connectedAppName) {
        // Step 1: Retrieve certificate content
        String certResponse = readMetadata('Certificate', certificateName);
        String certContent = extractXmlValue(certResponse, 'content');

        if (String.isBlank(certContent)) {
            throw new SetupException('Failed to retrieve certificate content');
        }

        // Step 2: Retrieve connected app
        String appResponse = readMetadata('ConnectedApp', connectedAppName);

        // Step 3: Update connected app with certificate
        String updatedAppXml = injectCertificateIntoConnectedApp(appResponse, certContent);

        String updateResponse = executeMetadataApiCall('updateMetadata', updatedAppXml);

        if (!isSuccessResponse(updateResponse)) {
            throw new SetupException('Failed to enable digital signatures: ' + extractErrorMessage(updateResponse));
        }
    }

    private static String createExternalCredential(String consumerKey, ComponentConfig config) {
        try {
            ConnectApi.ExternalCredentialInput input = new ConnectApi.ExternalCredentialInput();
            input.developerName = EXTERNAL_CREDENTIAL_API_NAME;
            input.masterLabel = EXTERNAL_CREDENTIAL_LABEL;
            input.authenticationProtocol = ConnectApi.CredentialAuthenticationProtocol.OAuth;
            input.authenticationProtocolVariant = ConnectApi.CredentialAuthenticationProtocolVariant.JwtBearer;

            // Setup principal
            input.principals = createExternalCredentialPrincipals();

            // Setup parameters
            input.parameters = createExternalCredentialParameters(consumerKey);

            // Create the credential
            ConnectApi.ExternalCredential credential = ConnectApi.NamedCredentials.createExternalCredential(input);

            // Grant permission set access
            grantPermissionSetAccess(config.permissionSetName, credential.principals[0].id);

            return credential.developerName;
        } catch (Exception e) {
            throw new SetupException('External Credential creation failed: ' + e.getMessage());
        }
    }

    private static String createNamedCredential() {
        try {
            ConnectApi.NamedCredentialInput input = new ConnectApi.NamedCredentialInput();
            input.developerName = NAMED_CREDENTIAL_API_NAME;
            input.masterLabel = NAMED_CREDENTIAL_LABEL;
            input.type = ConnectApi.NamedCredentialType.SecuredEndpoint;
            input.calloutUrl = Url.getOrgDomainUrl().toExternalForm();
            // TODO
            // input.calloutStatus = ConnectApi.CalloutStatus.Enabled;

            // Link to external credential
            input.externalCredentials = new List<ConnectApi.ExternalCredentialInput>{ createExternalCredentialReference() };

            // Configure callout options
            input.calloutOptions = createCalloutOptions();

            ConnectApi.NamedCredential credential = ConnectApi.NamedCredentials.createNamedCredential(input);

            return credential.developerName;
        } catch (Exception e) {
            throw new SetupException('Named Credential creation failed: ' + e.getMessage());
        }
    }

    private static String executeMetadataApiCall(String operation, String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(Url.getOrgDomainUrl().toExternalForm() + '/services/Soap/m/' + METADATA_API_VERSION);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'text/xml');
        req.setHeader('SOAPAction', '""');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());

        String envelope = wrapInSoapEnvelope(operation, body);
        req.setBody(envelope);

        try {
            HttpResponse res = new Http().send(req);
            return res.getBody();
        } catch (Exception e) {
            throw new SetupException('Metadata API call failed: ' + e.getMessage());
        }
    }

    private static String readMetadata(String metadataType, String fullName) {
        String body = '<type>' + metadataType + '</type>' + '<fullNames>' + fullName + '</fullNames>';

        return executeMetadataApiCall('readMetadata', body);
    }

    private static String wrapInSoapEnvelope(String operation, String body) {
        return '<?xml version="1.0" encoding="UTF-8"?>' +
            '<env:Envelope xmlns:env="' +
            ENVELOPE_NAMESPACE +
            '" ' +
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
            '<env:Header>' +
            '<SessionHeader xmlns="' +
            SOAP_NAMESPACE +
            '">' +
            '<sessionId>' +
            UserInfo.getSessionId() +
            '</sessionId>' +
            '</SessionHeader>' +
            '</env:Header>' +
            '<env:Body>' +
            '<' +
            operation +
            ' xmlns="' +
            SOAP_NAMESPACE +
            '">' +
            body +
            '</' +
            operation +
            '>' +
            '</env:Body>' +
            '</env:Envelope>';
    }

    private static String generateConsumerKey() {
        String orgId = UserInfo.getOrganizationId();
        String timestamp = String.valueOf(Datetime.now().getTime());
        String randomComponent = EncodingUtil.convertToHex(Crypto.generateAesKey(128));

        return orgId.substring(0, 15) + '.' + timestamp + '.' + randomComponent;
    }

    private static String getEnvironmentUrl(String path) {
        Organization org = [SELECT IsSandbox FROM Organization LIMIT 1];
        String baseUrl = org.IsSandbox ? 'https://test.salesforce.com' : 'https://login.salesforce.com';
        return baseUrl + path;
    }

    private static Boolean isSuccessResponse(String response) {
        return response.contains('<success>true</success>');
    }

    private static String extractErrorMessage(String response) {
        String error = extractXmlValue(response, 'message');
        return String.isNotBlank(error) ? error : 'Unknown error';
    }

    private static String extractXmlValue(String xml, String tagName) {
        String startTag = '<' + tagName + '>';
        String endTag = '</' + tagName + '>';

        Integer startIndex = xml.indexOf(startTag);
        Integer endIndex = xml.indexOf(endTag);

        if (startIndex != -1 && endIndex != -1) {
            return xml.substring(startIndex + startTag.length(), endIndex);
        }

        return null;
    }

    private static String buildCreateMetadataBody(String metadataType, Map<String, String> fields) {
        String body = '<metadata xsi:type="' + metadataType + '">';

        for (String key : fields.keySet()) {
            body += '<' + key + '>' + fields.get(key) + '</' + key + '>';
        }

        body += '</metadata>';

        return body;
    }

    private static String buildOAuthConfig(String certificateName, String consumerKey, String callbackUrl) {
        return '<oauthConfig>' +
            '<callbackUrl>' +
            callbackUrl +
            '</callbackUrl>' +
            '<certificate>' +
            certificateName +
            '</certificate>' +
            '<consumerKey>' +
            consumerKey +
            '</consumerKey>' +
            '<isAdminApproved>true</isAdminApproved>' +
            '<isClientCredentialEnabled>false</isClientCredentialEnabled>' +
            '<isCodeCredentialEnabled>false</isCodeCredentialEnabled>' +
            '<isCodeCredentialPostOnly>false</isCodeCredentialPostOnly>' +
            '<isConsumerSecretOptional>false</isConsumerSecretOptional>' +
            '<isIntrospectAllTokens>false</isIntrospectAllTokens>' +
            '<isNamedUserJwtEnabled>false</isNamedUserJwtEnabled>' +
            '<isPkceRequired>true</isPkceRequired>' +
            '<isRefreshTokenRotationEnabled>false</isRefreshTokenRotationEnabled>' +
            '<isSecretRequiredForRefreshToken>true</isSecretRequiredForRefreshToken>' +
            '<isSecretRequiredForTokenExchange>false</isSecretRequiredForTokenExchange>' +
            '<isTokenExchangeEnabled>false</isTokenExchangeEnabled>' +
            '<scopes>Api</scopes>' +
            '<scopes>RefreshToken</scopes>' +
            '</oauthConfig>';
    }

    private static String buildConnectedAppCreateRequest(Map<String, String> fields, String oauthConfig, String permissionSetName) {
        String body = '<metadata xsi:type="ConnectedApp">';

        // Add basic fields
        for (String key : fields.keySet()) {
            body += '<' + key + '>' + fields.get(key) + '</' + key + '>';
        }

        // Add OAuth config
        body += oauthConfig;

        // Add OAuth policy
        body +=
            '<oauthPolicy>' +
            '<ipRelaxation>ENFORCE</ipRelaxation>' +
            '<isTokenExchangeFlowEnabled>false</isTokenExchangeFlowEnabled>' +
            '<refreshTokenPolicy>infinite</refreshTokenPolicy>' +
            '</oauthPolicy>';

        // Add permission set
        body += '<permissionSetName>' + permissionSetName + '</permissionSetName>';

        body += '</metadata>';

        return body;
    }

    private static String injectCertificateIntoConnectedApp(String appXml, String certContent) {
        // Extract the ConnectedApp XML from the response
        String appStart = '<result><records xsi:type="ConnectedApp">';
        String appEnd = '</records>';

        Integer startIdx = appXml.indexOf(appStart);
        Integer endIdx = appXml.indexOf(appEnd);

        if (startIdx == -1 || endIdx == -1) {
            throw new SetupException('Failed to parse Connected App XML');
        }

        String connectedAppContent = appXml.substring(startIdx + appStart.length(), endIdx);

        // Inject certificate before </oauthConfig>
        String oauthConfigEnd = '</oauthConfig>';
        String certificateTag = '<certificate>' + certContent + '</certificate>';

        connectedAppContent = connectedAppContent.replace(oauthConfigEnd, certificateTag + oauthConfigEnd);

        // Wrap in update metadata format
        return '<metadata xsi:type="ConnectedApp">' + connectedAppContent + '</metadata>';
    }

    private static List<ConnectApi.ExternalCredentialPrincipalInput> createExternalCredentialPrincipals() {
        ConnectApi.ExternalCredentialPrincipalInput principal = new ConnectApi.ExternalCredentialPrincipalInput();
        principal.principalName = 'ServiceUserPrincipal';
        principal.principalType = ConnectApi.CredentialPrincipalType.NamedPrincipal;
        principal.sequenceNumber = 1;

        return new List<ConnectApi.ExternalCredentialPrincipalInput>{ principal };
    }

    private static List<ConnectApi.ExternalCredentialParameterInput> createExternalCredentialParameters(String consumerKey) {
        List<ConnectApi.ExternalCredentialParameterInput> parameters = new List<ConnectApi.ExternalCredentialParameterInput>();

        // Auth Provider URL
        parameters.add(
            createParameter(
                'AuthProviderUrl',
                ConnectApi.ExternalCredentialParameterType.AuthProviderUrl,
                Url.getOrgDomainUrl().toExternalForm() + '/services/oauth2/token'
            )
        );

        // Signing Certificate
        parameters.add(createParameter('SigningCertificate', ConnectApi.ExternalCredentialParameterType.SigningCertificate, CERTIFICATE_API_NAME));

        // JWT Claims
        String audienceUrl = getEnvironmentUrl('');

        // Issuer
        parameters.add(createParameter('iss', ConnectApi.ExternalCredentialParameterType.JwtBodyClaim, consumerKey));

        User serviceUser = [SELECT Id, Username FROM User WHERE Name = 'Service User'];

        // Subject
        parameters.add(createParameter('sub', ConnectApi.ExternalCredentialParameterType.JwtBodyClaim, serviceUser.Username));

        // Audience
        parameters.add(createParameter('aud', ConnectApi.ExternalCredentialParameterType.JwtBodyClaim, '"' + audienceUrl + '"'));

        return parameters;
    }

    private static ConnectApi.ExternalCredentialParameterInput createParameter(
        String name,
        ConnectApi.ExternalCredentialParameterType type,
        String value
    ) {
        ConnectApi.ExternalCredentialParameterInput param = new ConnectApi.ExternalCredentialParameterInput();
        param.parameterName = name;
        param.parameterType = type;
        param.parameterValue = value;
        return param;
    }

    private static ConnectApi.ExternalCredentialInput createExternalCredentialReference() {
        ConnectApi.ExternalCredentialInput ref = new ConnectApi.ExternalCredentialInput();
        ref.developerName = EXTERNAL_CREDENTIAL_API_NAME;
        return ref;
    }

    private static ConnectApi.NamedCredentialCalloutOptionsInput createCalloutOptions() {
        ConnectApi.NamedCredentialCalloutOptionsInput options = new ConnectApi.NamedCredentialCalloutOptionsInput();
        options.allowMergeFieldsInBody = false;
        options.allowMergeFieldsInHeader = false;
        options.generateAuthorizationHeader = true;
        return options;
    }

    private static void grantPermissionSetAccess(String permissionSetName, String principalId) {
        PermissionSet ps = [
            SELECT Id
            FROM PermissionSet
            WHERE Label = :permissionSetName
            WITH USER_MODE
            LIMIT 1
        ];

        try {
            insert as user new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = principalId);
        } catch (DmlException e) {
            // Access might already exist
            if (!e.getMessage().contains('DUPLICATE_VALUE')) {
                throw new SetupException('Failed to grant permission set access: ' + e.getMessage());
            }
        }
    }

    public class SetupException extends Exception {
    }

    private static Boolean checkExternalCredentialExists() {
        try {
            ConnectApi.NamedCredentials.getExternalCredential(EXTERNAL_CREDENTIAL_API_NAME);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private static Boolean checkNamedCredentialExists() {
        try {
            ConnectApi.NamedCredentials.getNamedCredential(NAMED_CREDENTIAL_API_NAME);
            return true;
        } catch (Exception e) {
            return false;
        }
    }
}
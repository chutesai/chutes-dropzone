import {
	IExecuteFunctions,
	ILoadOptionsFunctions,
	IHookFunctions,
	IWebhookFunctions,
	NodeApiError,
	IDataObject,
	IHttpRequestMethods,
	IRequestOptions,
} from 'n8n-workflow';

const grantedScopeCache = new Map<string, string[]>();
let hasLoggedSsoProxyBypass = false;
let cachedPublicTextModels:
	| Array<{ id?: string; name?: string; confidential_compute?: boolean }>
	| null = null;

function toTrimmedString(value: unknown): string {
	if (value === undefined || value === null) {
		return '';
	}

	return String(value).trim();
}

function normalizeBaseUrl(value: string): string {
	return value.replace(/\/+$/, '');
}

function isTruthyEnv(value: unknown): boolean {
	const normalized = toTrimmedString(value).toLowerCase();
	return normalized === '1' || normalized === 'true' || normalized === 'yes' || normalized === 'y';
}

/**
 * Resource types map to chute subdomains
 */
export type ChuteResourceType =
	| 'textGeneration'
	| 'imageGeneration'
	| 'videoGeneration'
	| 'audioGeneration'
	| 'textToSpeech'
	| 'speechToText'
	| 'inference'
	| 'embeddings'
	| 'musicGeneration'
	| 'contentModeration';

export function parseGrantedScopes(grantedScopes: unknown): string[] {
	if (Array.isArray(grantedScopes)) {
		return grantedScopes
			.map((value) => String(value).trim())
			.filter(Boolean);
	}

	if (typeof grantedScopes === 'string') {
		return grantedScopes
			.split(/\s+/)
			.map((value) => value.trim())
			.filter(Boolean);
	}

	return [];
}

async function introspectGrantedScopes(sessionToken: string): Promise<string[]> {
	/* istanbul ignore next */
	if (!sessionToken) {
		return [];
	}

	const cachedScopes = grantedScopeCache.get(sessionToken);
	if (cachedScopes) {
		return cachedScopes;
	}

	const clientId = toTrimmedString(process.env.CHUTES_OAUTH_CLIENT_ID);
	const clientSecret = toTrimmedString(process.env.CHUTES_OAUTH_CLIENT_SECRET);
	if (!clientId || !clientSecret) {
		return [];
	}

	const configuredIdpBaseUrl = toTrimmedString(process.env.CHUTES_IDP_BASE_URL);
	const idpBaseUrl = (configuredIdpBaseUrl || 'https://api.chutes.ai').replace(/\/+$/, '');
	const response = await fetch(`${idpBaseUrl}/idp/token/introspect`, {
		method: 'POST',
		headers: {
			Authorization: `Basic ${Buffer.from(`${clientId}:${clientSecret}`).toString('base64')}`,
			'Content-Type': 'application/x-www-form-urlencoded',
			Accept: 'application/json',
		},
		body: new URLSearchParams({
			token: sessionToken,
		}),
	});

	if (!response.ok) {
		return [];
	}

	const data = (await response.json()) as { scope?: string };
	const scopes = parseGrantedScopes(data.scope);
	grantedScopeCache.set(sessionToken, scopes);
	return scopes;
}

async function ensureChutesInvokeScope(credentials: IDataObject): Promise<void> {
	if (toTrimmedString(credentials.apiKey)) {
		return;
	}

	if (toTrimmedString(credentials.authType) !== 'sso') {
		return;
	}

	let grantedScopes = parseGrantedScopes(credentials.grantedScopes);
	const sessionToken = toTrimmedString(credentials.sessionToken);
	if (grantedScopes.length === 0) {
		grantedScopes = await introspectGrantedScopes(sessionToken);
	}

	if (grantedScopes.length === 0) {
		return;
	}

	if (
		grantedScopes.includes('admin') ||
		grantedScopes.includes('invoke') ||
		grantedScopes.includes('chutes:invoke')
	) {
		return;
	}

	const grantedList = grantedScopes.join(' ');
	throw new Error(
		`This Chutes SSO credential cannot invoke models because it was granted only: ${grantedList}. Continue with Chutes again, and if you already approved this app once, revoke the existing n8n authorization in your Chutes account settings before retrying so the credential is reauthorized with chutes:invoke.`,
	);
}

export function isChutesProxyMode(): boolean {
	return toTrimmedString(process.env.CHUTES_TRAFFIC_MODE) === 'e2ee-proxy';
}

export function getChutesProxyBaseUrl(): string {
	return normalizeBaseUrl(toTrimmedString(process.env.CHUTES_PROXY_BASE_URL));
}

export function isStrictTeeOnlyTextProxyMode(): boolean {
	return isChutesProxyMode() && !isTruthyEnv(process.env.ALLOW_NON_CONFIDENTIAL);
}

export function isSsoProxyBypassEnabled(): boolean {
	return isChutesProxyMode() && isTruthyEnv(process.env.CHUTES_SSO_PROXY_BYPASS);
}

export function isChutesSsoCredential(credentials: IDataObject | undefined): boolean {
	if (!credentials) {
		return false;
	}

	if (toTrimmedString(credentials.apiKey)) {
		return false;
	}

	if (toTrimmedString(credentials.authType) === 'sso') {
		return true;
	}

	return Boolean(toTrimmedString(credentials.sessionToken));
}

export function shouldUseTextProxyForCredential(credentials: IDataObject | undefined): boolean {
	return isChutesProxyMode() && !(isChutesSsoCredential(credentials) && isSsoProxyBypassEnabled());
}

function isAbsoluteUrl(value: string): boolean {
	return /^https?:\/\//i.test(value);
}

function shouldUseTextE2EEProxy(
	resourceType: ChuteResourceType | undefined,
	endpoint: string,
	credentials: IDataObject | undefined,
): boolean {
	return (
		shouldUseTextProxyForCredential(credentials) &&
		resourceType === 'textGeneration' &&
		endpoint.startsWith('/v1/')
	);
}

function shouldBypassTextProxyForSso(
	resourceType: ChuteResourceType | undefined,
	endpoint: string,
	credentials: IDataObject | undefined,
): boolean {
	return (
		isSsoProxyBypassEnabled() &&
		isChutesSsoCredential(credentials) &&
		resourceType === 'textGeneration' &&
		endpoint.startsWith('/v1/')
	);
}

function ensureTextModelSelection(requestBody: IDataObject, selectedTextTarget: string): void {
	if (toTrimmedString(requestBody.model) || !selectedTextTarget || isAbsoluteUrl(selectedTextTarget)) {
		return;
	}

	requestBody.model = selectedTextTarget;
}

function getDirectTextBaseUrl(credentials: IDataObject, selectedTextTarget: string): string {
	if (selectedTextTarget && isAbsoluteUrl(selectedTextTarget)) {
		return selectedTextTarget;
	}

	return getChutesBaseUrl(credentials, 'textGeneration');
}

function logSsoProxyBypassOnce(): void {
	if (hasLoggedSsoProxyBypass) {
		return;
	}

	hasLoggedSsoProxyBypass = true;
	console.warn(
		'Chutes SSO text requests are bypassing e2ee-proxy and using native Chutes LLM endpoints until the backend /e2e auth path supports SSO correctly. Set CHUTES_SSO_PROXY_BYPASS=false after that backend fix is deployed.',
	);
}

async function getPublicTextModels(): Promise<
	Array<{ id?: string; name?: string; confidential_compute?: boolean }>
> {
	if (cachedPublicTextModels) {
		return cachedPublicTextModels;
	}

	const response = await fetch('https://llm.chutes.ai/v1/models', {
		headers: {
			Accept: 'application/json',
		},
	});

	if (!response.ok) {
		throw new Error(`Failed to fetch public text models (${response.status})`);
	}

	const data = (await response.json()) as
		| { data?: Array<{ id?: string; name?: string; confidential_compute?: boolean }> }
		| Array<{ id?: string; name?: string; confidential_compute?: boolean }>;

	cachedPublicTextModels = Array.isArray(data) ? data : Array.isArray(data.data) ? data.data : [];
	return cachedPublicTextModels;
}

export async function ensureTextModelAllowedInCurrentTrafficMode(modelId: string): Promise<void> {
	if (!isStrictTeeOnlyTextProxyMode()) {
		return;
	}

	const normalizedModelId = toTrimmedString(modelId);
	if (!normalizedModelId) {
		throw new Error(
			'Strict TEE-only e2ee-proxy mode requires an explicit TEE text model selection.',
		);
	}

	const models = await getPublicTextModels();
	const match = models.find((model) => toTrimmedString(model.id) === normalizedModelId);
	if (!match) {
		throw new Error(
			`Strict TEE-only e2ee-proxy mode could not verify whether '${normalizedModelId}' is a TEE model. Choose a known TEE model or allow non-TEE text models.`,
		);
	}

	if (!match.confidential_compute) {
		throw new Error(
			`Strict TEE-only e2ee-proxy mode does not allow the non-TEE text model '${normalizedModelId}'. Choose a TEE model or allow non-TEE text models.`,
		);
	}
}

/**
 * Get the appropriate Chutes.ai base URL for a given resource type
 *
 * @param credentials - Chutes.ai credentials
 * @param resourceType - Type of resource (textGeneration, imageGeneration, etc.)
 * @param customChuteUrl - Custom chute URL selected by user in node parameter
 * @returns Base URL for the specific chute
 */
export function getChutesBaseUrl(
	credentials: IDataObject,
	resourceType?: ChuteResourceType,
	customChuteUrl?: string,
): string {
	if (customChuteUrl) {
		return customChuteUrl;
	}

	if (credentials.customUrl) {
		return credentials.customUrl as string;
	}

	const chuteSubdomains: Record<ChuteResourceType, string> = {
		textGeneration: 'llm',
		imageGeneration: 'image',
		videoGeneration: 'video',
		audioGeneration: 'audio',
		textToSpeech: 'audio',
		speechToText: 'stt',
		inference: 'llm',
		embeddings: 'llm',
		musicGeneration: 'audio',
		contentModeration: 'llm',
	};

	const subdomain = resourceType ? chuteSubdomains[resourceType] : 'llm';

	if (credentials.environment === 'sandbox') {
		return `https://sandbox-${subdomain}.chutes.ai`;
	}

	return `https://${subdomain}.chutes.ai`;
}

export async function chutesApiRequest(
	this: IExecuteFunctions | ILoadOptionsFunctions | IHookFunctions | IWebhookFunctions,
	method: IHttpRequestMethods,
	endpoint: string,
	body: IDataObject = {},
	qs: IDataObject = {},
	headers: IDataObject = {},
	option: IDataObject = {},
	resourceType?: ChuteResourceType,
	customChuteUrl?: string,
): Promise<any> {
	const credentials = await this.getCredentials('chutesApi');
	await ensureChutesInvokeScope(credentials);

	const selectedTextTarget = toTrimmedString(customChuteUrl);
	let baseUrl = getChutesBaseUrl(credentials, resourceType, customChuteUrl);
	const requestBody = { ...body };
	const requestHeaders: IDataObject = {
		'Content-Type': 'application/json',
		Accept: 'application/json',
		'User-Agent': 'n8n-ChutesAI/0.0.9',
		'X-Chutes-Source': 'n8n-integration',
		...headers,
	};

	if (resourceType === 'textGeneration' && endpoint.startsWith('/v1/')) {
		const explicitModelId =
			toTrimmedString(requestBody.model) ||
			(selectedTextTarget && !isAbsoluteUrl(selectedTextTarget) ? selectedTextTarget : '');
		await ensureTextModelAllowedInCurrentTrafficMode(explicitModelId);
	}

	if (shouldBypassTextProxyForSso(resourceType, endpoint, credentials)) {
		ensureTextModelSelection(requestBody, selectedTextTarget);
		baseUrl = getDirectTextBaseUrl(credentials, selectedTextTarget);
		logSsoProxyBypassOnce();
	} else if (shouldUseTextE2EEProxy(resourceType, endpoint, credentials)) {
		const proxyBaseUrl = getChutesProxyBaseUrl();
		if (!proxyBaseUrl) {
			throw new Error('CHUTES_PROXY_BASE_URL is not configured for e2ee-proxy mode.');
		}

		if (!toTrimmedString(requestBody.model)) {
			if (selectedTextTarget && !isAbsoluteUrl(selectedTextTarget)) {
				requestBody.model = selectedTextTarget;
			} else {
				throw new Error(
					'e2ee-proxy mode expects a text model id, but this workflow still has a chute URL selected. Re-select the text model in the Chutes node or switch traffic mode to direct.',
				);
			}
		}

		baseUrl = proxyBaseUrl;
	}

	const options: IRequestOptions = {
		method,
		headers: requestHeaders,
		url: `${baseUrl}${endpoint}`,
		qs,
		body: requestBody,
		json: true,
		encoding: 'utf8',
		...option,
	};

	if (method === 'GET' && options.body !== undefined) {
		delete options.body;
	}

	try {
		const response = await this.helpers.requestWithAuthentication.call(
			this,
			'chutesApi',
			options,
		);

		return response;
	} catch (error) {
		throw new NodeApiError(this.getNode(), error as any, {
			message: `Chutes.ai API error: ${(error as any).message}`,
			description: `Error from Chutes.ai: ${(error as any).description || 'Check your API key and parameters'}`,
		});
	}
}

export async function chutesApiRequestWithRetry(
	this: IExecuteFunctions | ILoadOptionsFunctions,
	method: IHttpRequestMethods,
	endpoint: string,
	body: IDataObject = {},
	qs: IDataObject = {},
	headers: IDataObject = {},
	option: IDataObject = {},
	resourceType?: ChuteResourceType,
	customChuteUrl?: string,
): Promise<any> {
	const maxRetries = 3;
	const baseDelay = 1000;

	const getStatusCode = (error: { statusCode?: number | string; httpCode?: number | string }) => {
		if (typeof error.httpCode === 'number') {
			return Number.isNaN(error.httpCode) ? undefined : error.httpCode;
		}

		if (typeof error.httpCode === 'string' && error.httpCode.trim()) {
			const parsedStatusCode = Number.parseInt(error.httpCode, 10);
			return Number.isNaN(parsedStatusCode) ? undefined : parsedStatusCode;
		}

		return undefined;
	};

	for (let attempt = 0; attempt <= maxRetries; attempt++) {
		try {
			const response = await chutesApiRequest.call(
				this,
				method,
				endpoint,
				body,
				qs,
				headers,
				option,
				resourceType,
				customChuteUrl,
			);

			if (response.headers) {
				const remaining = response.headers['x-ratelimit-remaining'];
				if (remaining && Number.parseInt(remaining, 10) < 10) {
					console.warn(`Chutes.ai rate limit remaining: ${remaining}`);
				}
			}

			return response;
		} catch (error: any) {
			const statusCode = getStatusCode(error);
			const isRetryable =
				statusCode === 429 ||
				statusCode === 500 ||
				statusCode === 502 ||
				statusCode === 503 ||
				statusCode === 504;

			if (!isRetryable || attempt === maxRetries) {
				throw error;
			}

			const delay = baseDelay * 2 ** attempt;
			console.warn(
				`Chutes.ai request failed (attempt ${attempt + 1}/${maxRetries + 1}), retrying in ${delay}ms...`,
			);
			await new Promise((resolve) => setTimeout(resolve, delay));
		}
	}

	throw new Error('Chutes.ai request failed after retries');
}

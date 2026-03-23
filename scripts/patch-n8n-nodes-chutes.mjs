import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const buildDir = process.argv[2];
const overlayRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

if (!buildDir) {
	console.error('Usage: node patch-n8n-nodes-chutes.mjs <build-dir>');
	process.exit(1);
}

function replaceOrThrow(source, needle, replacement, filePath) {
	if (!source.includes(needle)) {
		throw new Error(`Could not find patch marker in ${filePath}`);
	}

	return source.replace(needle, replacement);
}

function replaceRegexOrThrow(source, pattern, replacement, filePath) {
	if (!pattern.test(source)) {
		throw new Error(`Could not find patch marker in ${filePath}`);
	}

	return source.replace(pattern, replacement);
}

function copyOverlayFile(sourceRelativePath, destinationRelativePath) {
	const source = path.join(overlayRoot, sourceRelativePath);
	const destination = path.join(buildDir, destinationRelativePath);
	fs.mkdirSync(path.dirname(destination), { recursive: true });
	fs.copyFileSync(source, destination);
}

const RESOURCE_PLACEHOLDER_VALUE = '__choose_resource_type__';

function patchLegacyLoadChutesCompatibility() {
	const loadChutesFile = path.join(buildDir, 'nodes', 'Chutes', 'methods', 'loadChutes.ts');
	let source = fs.readFileSync(loadChutesFile, 'utf8');

	if (source.includes('requestWithChutesCredential')) {
		fs.writeFileSync(loadChutesFile, source);
		return;
	}

	source = replaceOrThrow(
		source,
		`import { ILoadOptionsFunctions, INodePropertyOptions } from 'n8n-workflow';
`,
		`import { ILoadOptionsFunctions, INodePropertyOptions } from 'n8n-workflow';
import { requestWithChutesCredential } from '../transport/requestWithChutesCredential';
`,
		loadChutesFile,
	);

	source = replaceOrThrow(
		source,
		`export interface ChutesListResponse {
\ttotal: number;
\tpage: number;
\tlimit: number;
\titems: ChuteOption[];
\tcord_refs: Record<string, any>;
}
`,
		`export interface ChutesListResponse {
\ttotal: number;
\tpage: number;
\tlimit: number;
\titems: ChuteOption[];
\tcord_refs: Record<string, any>;
}

let hasLoggedPublicCatalogFallback = false;

function buildChutesListRequestUrl(includePublic: boolean, limit: number): string {
\tconst queryParams = new URLSearchParams({
\t\tinclude_public: String(includePublic),
\t\tlimit: String(limit),
\t});

\treturn \`https://api.chutes.ai/chutes/?\${queryParams}\`;
}

function isPermissionDeniedError(error: unknown): boolean {
\tif (!error || typeof error !== 'object') {
\t\treturn false;
\t}

\tconst candidate = error as {
\t\thttpCode?: string | number;
\t\tstatusCode?: string | number;
\t\tstatus?: string | number;
\t\tdescription?: string;
\t\tmessage?: string;
\t\tresponse?: {
\t\t\tstatus?: string | number;
\t\t};
\t\terror?: {
\t\t\tdetail?: string;
\t\t};
\t};

\tconst statusCode = String(
\t\tcandidate.httpCode ??
\t\t\tcandidate.statusCode ??
\t\t\tcandidate.status ??
\t\t\tcandidate.response?.status ??
\t\t\t'',
\t).trim();

\tif (statusCode !== '403') {
\t\treturn false;
\t}

\tconst details = [candidate.description, candidate.message, candidate.error?.detail]
\t\t.filter((value): value is string => Boolean(value))
\t\t.join(' ')
\t\t.toLowerCase();

\treturn details.includes('permission') || details.includes('forbidden');
}

function isUnauthorizedError(error: unknown): boolean {
\tif (!error || typeof error !== 'object') {
\t\treturn false;
\t}

\tconst candidate = error as {
\t\thttpCode?: string | number;
\t\tstatusCode?: string | number;
\t\tstatus?: string | number;
\t\tdescription?: string;
\t\tmessage?: string;
\t\tresponse?: {
\t\t\tstatus?: string | number;
\t\t};
\t\terror?: {
\t\t\tdetail?: string;
\t\t};
\t};

\tconst statusCode = String(
\t\tcandidate.httpCode ??
\t\t\tcandidate.statusCode ??
\t\t\tcandidate.status ??
\t\t\tcandidate.response?.status ??
\t\t\t'',
\t).trim();

\tif (statusCode !== '401') {
\t\treturn false;
\t}

\tconst details = [candidate.description, candidate.message, candidate.error?.detail]
\t\t.filter((value): value is string => Boolean(value))
\t\t.join(' ')
\t\t.toLowerCase();

\treturn (
\t\tdetails.includes('invalid token') ||
\t\tdetails.includes('user not found') ||
\t\tdetails.includes('authorization failed') ||
\t\tdetails.includes('unauthorized')
\t);
}

function isMissingCredentialError(error: unknown): boolean {
\tif (!error || typeof error !== 'object') {
\t\treturn false;
\t}

\tconst candidate = error as {
\t\tdescription?: string;
\t\tmessage?: string;
\t};

\tconst details = [candidate.description, candidate.message]
\t\t.filter((value): value is string => Boolean(value))
\t\t.join(' ')
\t\t.toLowerCase();

\treturn (
\t\tdetails.includes('does not have any credentials set') ||
\t\tdetails.includes('missing both an api key and a session token') ||
\t\t(details.includes('credential') && details.includes('missing'))
\t);
}

function shouldFallbackToPublicCatalog(error: unknown): boolean {
\treturn (
\t\tisPermissionDeniedError(error) ||
\t\tisUnauthorizedError(error) ||
\t\tisMissingCredentialError(error)
\t);
}

async function requestPublicChutesWithoutAuth(
\tcontext: ILoadOptionsFunctions,
\turl: string,
): Promise<ChutesListResponse> {
\treturn await context.helpers.request({
\t\tjson: true,
\t\tmethod: 'GET',
\t\turl,
\t\theaders: {
\t\t\tAccept: 'application/json',
\t\t\t'Content-Type': 'application/json',
\t\t},
\t});
}
`,
		loadChutesFile,
	);

	source = replaceRegexOrThrow(
		source,
		/async function getRawChutes\(\s*context: ILoadOptionsFunctions,\s*includePublic = true,\s*limit = 500,\s*\): Promise<ChuteOption\[]> \{[\s\S]*?return chutesData\.items \|\| \[\];\n\}/,
		`async function getRawChutes(
\tcontext: ILoadOptionsFunctions,
\tincludePublic = true,
\tlimit = 500,
): Promise<ChuteOption[]> {
\tconst url = buildChutesListRequestUrl(includePublic, limit);

\tlet response: unknown;
\ttry {
\t\tresponse = await requestWithChutesCredential(context, {
\t\t\tmethod: 'GET',
\t\t\turl,
\t\t\theaders: {
\t\t\t\t'Content-Type': 'application/json',
\t\t\t},
\t\t});
\t} catch (error) {
\t\tif (!includePublic || !shouldFallbackToPublicCatalog(error)) {
\t\t\tthrow error;
\t\t}

\t\tif (!hasLoggedPublicCatalogFallback) {
\t\t\tconsole.warn(
\t\t\t\t'Authenticated chute discovery was unavailable, retrying the public catalog without credentials.',
\t\t\t);
\t\t\thasLoggedPublicCatalogFallback = true;
\t\t}
\t\tresponse = await requestPublicChutesWithoutAuth(context, url);
\t}

\tconst chutesData = response as ChutesListResponse;
\treturn chutesData.items || [];
}`,
		loadChutesFile,
	);

	fs.writeFileSync(loadChutesFile, source);
}

function patchCredentialTestBaseUrl() {
	const credentialFile = path.join(buildDir, 'credentials', 'ChutesApi.credentials.ts');
	let source = fs.readFileSync(credentialFile, 'utf8');

	const credentialOverlayFile = path.join(
		overlayRoot,
		'n8n-overlays',
		'n8n-nodes-chutes',
		'credentials',
		'ChutesApi.credentials.ts',
	);

	if (!source.includes('FORCE_REFRESH_FLAG')) {
		fs.copyFileSync(credentialOverlayFile, credentialFile);
		return;
	}

	if (!source.includes('CHUTES_CREDENTIAL_TEST_BASE_URL')) {
		const helperFunction = `function getCredentialTestBaseUrl(): string {
\treturn (
\t\tprocess.env.CHUTES_CREDENTIAL_TEST_BASE_URL?.trim() ||
\t\t'={{$credentials.customUrl || ($credentials.environment === "sandbox" ? "https://sandbox-llm.chutes.ai" : "https://llm.chutes.ai")}}'
\t);
}
`;
		const marker = "const FORCE_REFRESH_FLAG = '__n8nForceCredentialRefresh';\n";

		if (source.includes(marker)) {
			source = replaceOrThrow(
				source,
				marker,
				`${marker}
function getCredentialTestBaseUrl(): string {
\treturn (
\t\tprocess.env.CHUTES_CREDENTIAL_TEST_BASE_URL?.trim() ||
\t\t'={{$credentials.customUrl || ($credentials.environment === "sandbox" ? "https://sandbox-llm.chutes.ai" : "https://llm.chutes.ai")}}'
\t);
}
`,
				credentialFile,
			);
		} else {
			const exportMarker = '\nexport class ChutesApi implements ICredentialType {\n';
			source = replaceOrThrow(
				source,
				exportMarker,
				`\n${helperFunction}\nexport class ChutesApi implements ICredentialType {\n`,
				credentialFile,
			);
		}

		source = replaceRegexOrThrow(
			source,
			/baseURL:\s*(?:getCredentialTestBaseUrl\(\)|'=\{\{\$credentials\.customUrl \|\| \(\$credentials\.environment === "sandbox" \? "https:\/\/sandbox-llm\.chutes\.ai" : "https:\/\/llm\.chutes\.ai"\)\}\}')\s*,/,
			`baseURL: getCredentialTestBaseUrl(),`,
			credentialFile,
		);
	}

	fs.writeFileSync(credentialFile, source);
}

function patchTrafficModeRouting() {
	copyOverlayFile(
		'n8n-overlays/n8n-nodes-chutes/nodes/Chutes/transport/apiRequest.ts',
		'nodes/Chutes/transport/apiRequest.ts',
	);
	copyOverlayFile(
		'n8n-overlays/n8n-nodes-chutes/nodes/Chutes/transport/requestWithChutesCredential.ts',
		'nodes/Chutes/transport/requestWithChutesCredential.ts',
	);
	copyOverlayFile(
		'n8n-overlays/n8n-nodes-chutes/nodes/ChutesChatModel/GenericChutesChatModel.ts',
		'nodes/ChutesChatModel/GenericChutesChatModel.ts',
	);
}

function patchResourceChooser() {
	const nodeFile = path.join(buildDir, 'nodes', 'Chutes', 'Chutes.node.ts');
	let source = fs.readFileSync(nodeFile, 'utf8');

	if (source.includes(`value: '${RESOURCE_PLACEHOLDER_VALUE}'`)) {
		// Already patched.
	} else if (source.includes("name: 'Choose Resource Type'")) {
		source = source.replace(
			`name: 'Choose Resource Type',
\t\t\t\t\t\tvalue: '',`,
			`name: 'Choose Resource Type',
\t\t\t\t\t\tvalue: '${RESOURCE_PLACEHOLDER_VALUE}',`,
		);
	} else {
		source = replaceOrThrow(
			source,
			`options: [
\t\t\t\t\t{
\t\t\t\t\t\tname: 'LLM (Text Generation)',`,
			`options: [
\t\t\t\t\t{
\t\t\t\t\t\tname: 'Choose Resource Type',
\t\t\t\t\t\tvalue: '${RESOURCE_PLACEHOLDER_VALUE}',
\t\t\t\t\t\tdescription: 'Select the kind of Chutes model you want to use',
\t\t\t\t\t},
\t\t\t\t\t{
\t\t\t\t\t\tname: 'LLM (Text Generation)',`,
			nodeFile,
		);
	}

	if (source.includes(`default: 'textGeneration',`)) {
		source = source.replace(
			`default: 'textGeneration',`,
			`default: '${RESOURCE_PLACEHOLDER_VALUE}',`,
		);
	} else if (source.includes(`default: '',`)) {
		source = source.replace(
			`default: '',`,
			`default: '${RESOURCE_PLACEHOLDER_VALUE}',`,
		);
	}

	if (source.includes(`default: 'https://llm.chutes.ai',`)) {
		source = source.replace(
			`default: 'https://llm.chutes.ai',`,
			`default: '',`,
		);
	}

	if (source.includes(`placeholder: 'https://llm.chutes.ai',`)) {
		source = source.replace(
			`placeholder: 'https://llm.chutes.ai',`,
			`placeholder: 'Select a resource type first',`,
		);
	}

	const subtitleNeedleLegacy = `subtitle: '={{$parameter["operation"] + ": " + $parameter["resource"]}}',`;
	const subtitleNeedleCurrent = `subtitle: '={{$parameter["resource"] ? $parameter["operation"] + ": " + $parameter["resource"] : "choose resource"}}',`;
	const subtitleReplacement = `subtitle: '={{$parameter["resource"] && $parameter["resource"] !== "${RESOURCE_PLACEHOLDER_VALUE}" ? ($parameter["operation"] ? $parameter["operation"] + ": " : "") + $parameter["resource"] : "choose resource"}}',`;
	if (source.includes(subtitleNeedleLegacy)) {
		source = source.replace(subtitleNeedleLegacy, subtitleReplacement);
	}
	if (source.includes(subtitleNeedleCurrent)) {
		source = source.replace(subtitleNeedleCurrent, subtitleReplacement);
	}

	fs.writeFileSync(nodeFile, source);
}

function patchResourceAwareChuteLoading() {
	const loadChutesFile = path.join(buildDir, 'nodes', 'Chutes', 'methods', 'loadChutes.ts');
	let source = fs.readFileSync(loadChutesFile, 'utf8');

	if (!source.includes('requestWithChutesCredential') || !source.includes('getChutesForSelectedResource')) {
		// Older upstream node revisions still use resource-specific chute fields, so the
		// resource-aware shared-dropdown patch is not needed for that shape.
		return;
	}

	if (source.includes(`value: '${RESOURCE_PLACEHOLDER_VALUE}'`)) {
		// Already patched.
	} else if (source.includes('const SELECT_RESOURCE_TYPE_OPTION')) {
		source = source.replace(
			`const SELECT_RESOURCE_TYPE_OPTION: INodePropertyOptions = {
\tname: 'Select a resource type first',
\tvalue: '',
\tdescription: 'Choose a resource type to load matching chutes.',
};`,
			`const SELECT_RESOURCE_TYPE_OPTION: INodePropertyOptions = {
\tname: 'Select a resource type first',
\tvalue: '${RESOURCE_PLACEHOLDER_VALUE}',
\tdescription: 'Choose a resource type to load matching chutes.',
};`,
		);
	} else {
		source = replaceOrThrow(
			source,
			`let hasLoggedPublicCatalogFallback = false;
`,
			`let hasLoggedPublicCatalogFallback = false;

const SELECT_RESOURCE_TYPE_OPTION: INodePropertyOptions = {
\tname: 'Select a resource type first',
\tvalue: '${RESOURCE_PLACEHOLDER_VALUE}',
\tdescription: 'Choose a resource type to load matching chutes.',
};
`,
			loadChutesFile,
		);
	}

	if (source.includes(`return (context.getCurrentNodeParameter('resource') as string) || 'textGeneration';`)) {
		source = source.replace(
			`function getCurrentResource(context: ILoadOptionsFunctions): string {
\ttry {
\t\treturn (context.getCurrentNodeParameter('resource') as string) || 'textGeneration';
\t} catch {
\t\treturn '';
\t}
}`,
			`function getCurrentResource(context: ILoadOptionsFunctions): string {
\ttry {
\t\treturn String(context.getCurrentNodeParameter('resource') ?? '').trim();
\t} catch {
\t\treturn '${RESOURCE_PLACEHOLDER_VALUE}';
\t}
}`,
		);
	} else if (source.includes(`return String(context.getCurrentNodeParameter('resource') ?? '').trim();`)) {
		source = source.replace(
			`function getCurrentResource(context: ILoadOptionsFunctions): string {
\ttry {
\t\treturn String(context.getCurrentNodeParameter('resource') ?? '').trim();
\t} catch {
\t\treturn '';
\t}
}`,
			`function getCurrentResource(context: ILoadOptionsFunctions): string {
\ttry {
\t\treturn String(context.getCurrentNodeParameter('resource') ?? '').trim();
\t} catch {
\t\treturn '${RESOURCE_PLACEHOLDER_VALUE}';
\t}
}`,
		);
	}

	if (source.includes(`if (!resource) {\n\t\treturn [SELECT_RESOURCE_TYPE_OPTION];\n\t}`)) {
		source = source.replace(
			`if (!resource) {
\t\treturn [SELECT_RESOURCE_TYPE_OPTION];
\t}`,
			`if (!resource || resource === '${RESOURCE_PLACEHOLDER_VALUE}') {
\t\treturn [SELECT_RESOURCE_TYPE_OPTION];
\t}`,
		);
	} else if (!source.includes(`if (!resource || resource === '${RESOURCE_PLACEHOLDER_VALUE}') {\n\t\treturn [SELECT_RESOURCE_TYPE_OPTION];\n\t}`)) {
		source = replaceOrThrow(
			source,
			`): Promise<INodePropertyOptions[]> {
\tconst resource = getCurrentResource(this);

\tswitch (resource) {`,
			`): Promise<INodePropertyOptions[]> {
\tconst resource = getCurrentResource(this);

\tif (!resource || resource === '${RESOURCE_PLACEHOLDER_VALUE}') {
\t\treturn [SELECT_RESOURCE_TYPE_OPTION];
\t}

\tswitch (resource) {`,
			loadChutesFile,
		);
	}

	if (source.includes(`\t\tdefault:\n\t\t\treturn await getChutes.call(this);`)) {
		source = source.replace(
			`\t\tdefault:\n\t\t\treturn await getChutes.call(this);`,
			`\t\tdefault:\n\t\t\treturn [SELECT_RESOURCE_TYPE_OPTION];`,
		);
	}

	fs.writeFileSync(loadChutesFile, source);
}

function patchTextProxyModelSelection() {
	const loadChutesFile = path.join(buildDir, 'nodes', 'Chutes', 'methods', 'loadChutes.ts');
	let source = fs.readFileSync(loadChutesFile, 'utf8');

	if (!source.includes('getChutesForSelectedResource')) {
		fs.writeFileSync(loadChutesFile, source);
		return;
	}

	if (!source.includes('function isChutesTextProxyMode(): boolean')) {
		source = replaceOrThrow(
			source,
			`function buildChutesListRequestUrl(includePublic: boolean, limit: number): string {
`,
			`function isChutesTextProxyMode(): boolean {
\treturn String(process.env.CHUTES_TRAFFIC_MODE ?? '').trim() === 'e2ee-proxy';
}

function getTextProxyBaseUrl(): string {
\treturn String(process.env.CHUTES_PROXY_BASE_URL ?? '')
\t\t.trim()
\t\t.replace(/\\/+$/, '');
}

function isStrictTeeOnlyTextProxyMode(): boolean {
\tconst allowNonConfidential = String(process.env.ALLOW_NON_CONFIDENTIAL ?? '')
\t\t.trim()
\t\t.toLowerCase();

\treturn (
\t\tisChutesTextProxyMode() &&
\t\tallowNonConfidential !== 'true' &&
\t\tallowNonConfidential !== '1' &&
\t\tallowNonConfidential !== 'yes' &&
\t\tallowNonConfidential !== 'y'
\t);
}

function parseModelsResponse(response: any): any[] {
\tif (Array.isArray(response?.data)) {
\t\treturn response.data;
\t}

\tif (Array.isArray(response)) {
\t\treturn response;
\t}

\treturn [];
}

async function getProxyTextModelOptions(
\tcontext: ILoadOptionsFunctions,
): Promise<INodePropertyOptions[]> {
\tconst baseUrl = getTextProxyBaseUrl() || 'https://llm.chutes.ai';
\tlet response: any;

\ttry {
\t\tresponse = await requestWithChutesCredential(context, {
\t\t\tmethod: 'GET',
\t\t\turl: \`\${baseUrl}/v1/models\`,
\t\t\theaders: {
\t\t\t\t'Content-Type': 'application/json',
\t\t\t},
\t\t});
\t} catch (error) {
\t\tif (!shouldFallbackToPublicCatalog(error)) {
\t\t\tthrow error;
\t\t}

\t\tresponse = await context.helpers.request({
\t\t\tjson: true,
\t\t\tmethod: 'GET',
\t\t\turl: \`\${baseUrl}/v1/models\`,
\t\t\theaders: {
\t\t\t\tAccept: 'application/json',
\t\t\t\t'Content-Type': 'application/json',
\t\t\t},
\t\t});
\t}

\tconst models = parseModelsResponse(response).filter((model: any) => {
\t\tif (isStrictTeeOnlyTextProxyMode() && !model?.confidential_compute) {
\t\t\treturn false;
\t\t}

\t\tconst type = String(model?.type || '').toLowerCase();
\t\treturn !type || type.includes('text') || type.includes('chat') || type.includes('llm');
\t});

\tconst options: INodePropertyOptions[] = [];

\tfor (const model of models) {
\t\tconst modelId = String(model?.id || model?.name || '').trim();
\t\tif (!modelId) {
\t\t\tcontinue;
\t\t}

\t\tconst descriptionParts = [
\t\t\tmodel?.confidential_compute ? 'TEE' : null,
\t\t\tmodel?.context_length ? \`\${model.context_length} tokens\` : null,
\t\t\tmodel?.description || null,
\t\t].filter(Boolean);

\t\toptions.push({
\t\t\tname: model?.name ? \`\${model.name} - \${modelId}\` : modelId,
\t\t\tvalue: modelId,
\t\t\tdescription: descriptionParts.join(' | '),
\t\t});
\t}

\treturn options;
}

function buildChutesListRequestUrl(includePublic: boolean, limit: number): string {
`,
			loadChutesFile,
		);
	}

	if (
		!source.includes(
			`		case 'textGeneration':
			return await (isChutesTextProxyMode()`,
		)
	) {
		source = replaceOrThrow(
			source,
			`		case 'textGeneration':
			return await getLLMChutes.call(this);`,
			`		case 'textGeneration':
			return await (isChutesTextProxyMode()
				? getProxyTextModelOptions(this)
				: getLLMChutes.call(this));`,
			loadChutesFile,
		);
	}

	fs.writeFileSync(loadChutesFile, source);
}

function patchNeutralNodeCreatorFlow() {
	const operationsDir = path.join(buildDir, 'nodes', 'Chutes', 'operations');

	for (const entry of fs.readdirSync(operationsDir)) {
		if (!entry.endsWith('.ts')) {
			continue;
		}

		const operationFile = path.join(operationsDir, entry);
		const source = fs.readFileSync(operationFile, 'utf8');
		const patched = source.replace(/^\s*action: '.*?',\n/gm, '');

		if (patched !== source) {
			fs.writeFileSync(operationFile, patched);
		}
	}
}

patchCredentialTestBaseUrl();
patchTrafficModeRouting();
patchLegacyLoadChutesCompatibility();
patchResourceChooser();
patchResourceAwareChuteLoading();
patchTextProxyModelSelection();
patchNeutralNodeCreatorFlow();

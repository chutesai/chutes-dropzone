import { SimpleChatModel } from '@langchain/core/language_models/chat_models';
import { BaseMessage } from '@langchain/core/messages';
import { CallbackManagerForLLMRun } from '@langchain/core/callbacks/manager';
import { IDataObject } from 'n8n-workflow';
import {
	ensureTextModelAllowedInCurrentTrafficMode,
	getChutesProxyBaseUrl,
	isChutesSsoCredential,
	isStrictTeeOnlyTextProxyMode,
	isSsoProxyBypassEnabled,
	shouldUseTextProxyForCredential,
} from '../Chutes/transport/apiRequest';

interface ChutesChatModelConfig {
	chuteUrl: string;
	model: string;
	temperature?: number;
	maxTokens?: number;
	topP?: number;
	frequencyPenalty?: number;
	presencePenalty?: number;
	credentials: IDataObject;
	requestHelper: any;
	authenticatedRequest?: (requestOptions: IDataObject) => Promise<any>;
}

export class GenericChutesChatModel extends SimpleChatModel {
	chuteUrl: string;
	model: string;
	temperature: number;
	maxTokens: number;
	topP?: number;
	frequencyPenalty?: number;
	presencePenalty?: number;
	credentials: IDataObject;
	requestHelper: any;
	authenticatedRequest?: (requestOptions: IDataObject) => Promise<any>;

	constructor(config: ChutesChatModelConfig) {
		super({});
		this.chuteUrl = config.chuteUrl;
		this.model = config.model;
		this.temperature = config.temperature ?? 0.7;
		this.maxTokens = config.maxTokens ?? 1000;
		this.topP = config.topP;
		this.frequencyPenalty = config.frequencyPenalty;
		this.presencePenalty = config.presencePenalty;
		this.credentials = config.credentials;
		this.requestHelper = config.requestHelper;
		this.authenticatedRequest = config.authenticatedRequest;
	}

	_combineLLMOutput() {
		return {};
	}

	_llmType(): string {
		return 'chutes-chat-model';
	}

	async _call(
		messages: BaseMessage[],
		options: this['ParsedCallOptions'],
		runManager?: CallbackManagerForLLMRun,
	): Promise<string> {
		const formattedMessages = messages.map((message) => {
			let role: 'system' | 'user' | 'assistant';

			try {
				const messageType =
					typeof message._getType === 'function'
						? message._getType()
						: message.constructor.name.toLowerCase();

				if (messageType === 'system' || messageType.includes('system')) {
					role = 'system';
				} else if (messageType === 'human' || messageType.includes('human')) {
					role = 'user';
				} else if (messageType === 'ai' || messageType.includes('ai')) {
					role = 'assistant';
				} else {
					role = 'user';
				}
			} catch {
				role = 'user';
			}

			return {
				role,
				content:
					typeof message.content === 'string' ? message.content : JSON.stringify(message.content),
			};
		});

		const body: IDataObject = {
			messages: formattedMessages,
			stream: false,
		};

		const useTextProxy = shouldUseTextProxyForCredential(this.credentials);
		const ssoBypassesProxy =
			isSsoProxyBypassEnabled() && !useTextProxy && isChutesSsoCredential(this.credentials);

		if (this.model && this.model !== '') {
			body.model = this.model;
		} else if (isStrictTeeOnlyTextProxyMode()) {
			throw new Error(
				'Strict TEE-only e2ee-proxy mode requires an explicit TEE text model selection for Chutes Chat Model.',
			);
		} else if (useTextProxy && getChutesProxyBaseUrl()) {
			throw new Error(
				'e2ee-proxy mode expects an explicit model selection for Chutes Chat Model. Choose a model or switch traffic mode to direct.',
			);
		}
		if (this.temperature !== undefined) {
			body.temperature = this.temperature;
		}
		if (this.maxTokens !== undefined) {
			body.max_tokens = this.maxTokens;
		}
		if (this.topP !== undefined) {
			body.top_p = this.topP;
		}
		if (this.frequencyPenalty !== undefined) {
			body.frequency_penalty = this.frequencyPenalty;
		}
		if (this.presencePenalty !== undefined) {
			body.presence_penalty = this.presencePenalty;
		}
		if (options.stop) {
			body.stop = options.stop;
		}

		try {
			if (body.model) {
				await ensureTextModelAllowedInCurrentTrafficMode(String(body.model));
			}

			const requestUrl =
				useTextProxy && getChutesProxyBaseUrl()
					? `${getChutesProxyBaseUrl()}/v1/chat/completions`
					: `${this.chuteUrl}/v1/chat/completions`;
			const requestOptions: IDataObject = {
				method: 'POST',
				url: requestUrl,
				headers: {
					'Content-Type': 'application/json',
					Accept: 'application/json',
					'User-Agent': 'n8n-ChutesAI-ChatModel/0.0.9',
					'X-Chutes-Source': 'n8n-ai-agent',
				},
				body,
				json: true,
			};

			if (ssoBypassesProxy) {
				console.warn(
					'Chutes SSO chat-model requests are bypassing e2ee-proxy and using native Chutes LLM endpoints until the backend /e2e auth path supports SSO correctly. Set CHUTES_SSO_PROXY_BYPASS=false after that backend fix is deployed.',
				);
			}

			const response = this.authenticatedRequest
				? await this.authenticatedRequest(requestOptions)
				: await this.requestHelper.request({
						...requestOptions,
						headers: {
							...(requestOptions.headers as IDataObject),
							Authorization: `Bearer ${String(
								this.credentials.apiKey || this.credentials.sessionToken || '',
							)}`,
						},
					});

			if (runManager) {
				await runManager.handleLLMNewToken(response.choices[0].message.content ?? '');
			}

			return response.choices[0]?.message?.content ?? '';
		} catch (error: any) {
			const errorMessage = error.response?.data?.error?.message || error.message || 'Unknown error';
			throw new Error(`Chutes.ai API error: ${errorMessage}`);
		}
	}

	get modelName(): string {
		return this.model || 'chutes-default';
	}
}

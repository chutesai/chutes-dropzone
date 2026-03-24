import axios from 'axios';
import { GlobalConfig } from '@n8n/config';
import {
	AuthIdentity,
	AuthIdentityRepository,
	GLOBAL_ADMIN_ROLE,
	GLOBAL_MEMBER_ROLE,
	ProjectRepository,
	SharedCredentialsRepository,
	type User,
	UserRepository,
} from '@n8n/db';
import { Service } from '@n8n/di';
import { createHash, randomBytes } from 'crypto';

import { CredentialsService } from '@/credentials/credentials.service';
import { AuthError } from '@/errors/response-errors/auth.error';
import { JwtService } from '@/services/jwt.service';
import type { JwtPayload } from '@/services/jwt.service';
import { PasswordUtility } from '@/services/password.utility';
import { UrlService } from '@/services/url.service';

type ChutesFlowToken = JwtPayload & {
	state: string;
	verifier: string;
	redirectPath: string;
};

type ChutesTokenResponse = {
	access_token?: string;
	refresh_token?: string;
	token_type?: string;
	expires_in?: number;
	scope?: string;
};

type ChutesUserInfo = {
	sub?: string;
	username?: string;
	created_at?: string;
};

type ChutesQuotaItem = {
	chute_id?: string;
	quota?: number;
	is_default?: boolean;
};

type ChutesLiveQuota = {
	used?: number;
	quota?: number;
};

type ChutesAccount = {
	username?: string;
	logo?: string;
	permissions_bitmask?: number;
	balance?: number;
};

type ChutesManagedCredentialData = {
	authType?: string;
	apiKey?: string;
	environment?: string;
	customUrl?: string;
	sessionToken?: string;
	refreshToken?: string;
	tokenExpiresAt?: string;
	grantedScopes?: string;
	chutesSubject?: string;
	chutesUsername?: string;
};

type ManagedCredentialLookup = {
	credential: NonNullable<
		NonNullable<
			Awaited<ReturnType<SharedCredentialsRepository['findOne']>>
		>['credentials']
	>;
	data: ChutesManagedCredentialData;
};

class ChutesAccountUnauthorizedError extends Error {}

@Service()
export class ChutesSsoService {
	constructor(
		private readonly globalConfig: GlobalConfig,
		private readonly jwtService: JwtService,
		private readonly urlService: UrlService,
		private readonly credentialsService: CredentialsService,
		private readonly authIdentityRepository: AuthIdentityRepository,
		private readonly projectRepository: ProjectRepository,
		private readonly sharedCredentialsRepository: SharedCredentialsRepository,
		private readonly userRepository: UserRepository,
		private readonly passwordUtility: PasswordUtility,
	) {}

	beginLogin(redirectPath?: string) {
		if (!this.isEnabled()) {
			throw new AuthError('Chutes SSO is not configured');
		}

		const state = randomBytes(16).toString('hex');
		const verifier = randomBytes(32).toString('base64url');
		const challenge = createHash('sha256').update(verifier).digest('base64url');
		const normalizedRedirectPath = this.normalizeRedirectPath(redirectPath);

		const authorizationUrl = new URL(`${this.idpBaseUrl}/idp/authorize`);
		authorizationUrl.search = new URLSearchParams({
			response_type: 'code',
			client_id: this.clientId,
			redirect_uri: this.callbackUrl,
			scope: this.requestedScopes,
			state,
			code_challenge: challenge,
			code_challenge_method: 'S256',
		}).toString();

		const flowToken = this.jwtService.sign(
			{
				state,
				verifier,
				redirectPath: normalizedRedirectPath,
			},
			{ expiresIn: '10m' },
		);

		return {
			authorizationUrl: authorizationUrl.toString(),
			flowToken,
		};
	}

	async completeLogin({
		code,
		state,
		flowToken,
	}: {
		code?: string;
		state?: string;
		flowToken?: string;
	}) {
		if (!code || !state || !flowToken) {
			throw new AuthError('Missing Chutes SSO callback parameters');
		}

		const verifiedFlow = this.jwtService.verify<ChutesFlowToken>(flowToken);
		if (verifiedFlow.state !== state) {
			throw new AuthError('Invalid Chutes SSO state');
		}

		const tokenResponse = await this.exchangeCode(code, verifiedFlow.verifier);
		this.assertRequiredScopes(tokenResponse.scope);
		const userInfo = await this.getUserInfo(tokenResponse.access_token);
		const subject = userInfo.sub?.trim();
		const username = userInfo.username?.trim();

		if (!subject || !username) {
			throw new AuthError('Chutes user info is missing required claims');
		}

		const user = await this.findOrCreateUser(subject, username);
		await this.upsertManagedCredential(user, subject, username, tokenResponse);

		return {
			user,
			redirectPath: this.normalizeRedirectPath(verifiedFlow.redirectPath),
		};
	}

	async getAccountSummaryForUser(user: Pick<User, 'id' | 'email' | 'firstName'>) {
		let managedCredential: ManagedCredentialLookup;

		try {
			managedCredential = await this.getManagedCredentialForUser(user.id);
		} catch (error) {
			const fallbackCredential = await this.getAdminFallbackManagedCredential(user.id);
			if (!fallbackCredential) {
				throw error;
			}
			managedCredential = fallbackCredential;
		}

		try {
			const { account, quotas, liveQuota } = await this.fetchAccountBundle(
				managedCredential.data.sessionToken,
			);
			return this.buildAccountSummary(user, account, quotas, liveQuota);
		} catch (error) {
			if (!(error instanceof ChutesAccountUnauthorizedError)) {
				throw new AuthError('Failed to fetch the Chutes account summary');
			}
		}

		managedCredential = await this.refreshManagedCredential(managedCredential);
		const { account, quotas, liveQuota } = await this.fetchAccountBundle(
			managedCredential.data.sessionToken,
		);

		return this.buildAccountSummary(user, account, quotas, liveQuota);
	}

	private async exchangeCode(code: string, verifier: string) {
		const response = await axios.post<ChutesTokenResponse>(
			`${this.idpBaseUrl}/idp/token`,
			new URLSearchParams({
				grant_type: 'authorization_code',
				client_id: this.clientId,
				client_secret: this.clientSecret,
				code,
				code_verifier: verifier,
				redirect_uri: this.callbackUrl,
			}).toString(),
			{
				headers: {
					'Content-Type': 'application/x-www-form-urlencoded',
				},
				validateStatus: () => true,
			},
		);

		if (response.status !== 200 || !response.data.access_token) {
			throw new AuthError('Failed to exchange Chutes authorization code');
		}

		return response.data;
	}

	private async refreshAccessToken(refreshToken: string) {
		const response = await axios.post<ChutesTokenResponse>(
			`${this.idpBaseUrl}/idp/token`,
			new URLSearchParams({
				grant_type: 'refresh_token',
				client_id: this.clientId,
				client_secret: this.clientSecret,
				refresh_token: refreshToken,
			}).toString(),
			{
				headers: {
					'Content-Type': 'application/x-www-form-urlencoded',
				},
				validateStatus: () => true,
			},
		);

		if (response.status !== 200 || !response.data.access_token) {
			throw new AuthError('Failed to refresh the Chutes OAuth session');
		}

		return response.data;
	}

	private async getUserInfo(accessToken?: string) {
		if (!accessToken) {
			throw new AuthError('Chutes SSO token exchange did not return an access token');
		}

		const response = await axios.get<ChutesUserInfo>(`${this.idpBaseUrl}/idp/userinfo`, {
			headers: {
				Authorization: `Bearer ${accessToken}`,
			},
			validateStatus: () => true,
		});

		if (response.status !== 200) {
			throw new AuthError('Failed to fetch Chutes user info');
		}

		return response.data;
	}

	private async findOrCreateUser(subject: string, username: string) {
		const existingIdentity = await this.authIdentityRepository.findOne({
			where: {
				providerId: subject,
				providerType: 'chutes',
			},
			relations: {
				user: {
					authIdentities: true,
					role: true,
				},
			},
		});

		if (existingIdentity?.user) {
			if (existingIdentity.user.disabled) {
				throw new AuthError('This n8n account is disabled');
			}

			return await this.syncExistingUser(existingIdentity.user, username);
		}

		const syntheticEmail = this.syntheticEmail(subject);
		const userWithSyntheticEmail = await this.userRepository.findOne({
			where: { email: syntheticEmail },
			relations: ['authIdentities', 'role'],
		});

		if (userWithSyntheticEmail) {
			if (userWithSyntheticEmail.disabled) {
				throw new AuthError('This n8n account is disabled');
			}

			await this.attachIdentity(userWithSyntheticEmail, subject);
			return await this.syncExistingUser(userWithSyntheticEmail, username);
		}

		return await this.createUser(subject, username);
	}

	private async createUser(subject: string, username: string) {
		const password = await this.passwordUtility.hash(randomBytes(24).toString('hex'));
		const firstName = this.displayName(username);
		const role = this.shouldPromote(username) ? GLOBAL_ADMIN_ROLE : GLOBAL_MEMBER_ROLE;

		return await this.userRepository.manager.transaction(async (transactionManager) => {
			const { user } = await this.userRepository.createUserWithProject(
				{
					email: this.syntheticEmail(subject),
					firstName,
					lastName: 'Chutes',
					password,
					role,
				},
				transactionManager,
			);

			await transactionManager.save(AuthIdentity.create(user, subject, 'chutes'));
			return user;
		});
	}

	private async attachIdentity(user: User, subject: string) {
		const existingIdentity = user.authIdentities?.find((identity) => identity.providerType === 'chutes');
		if (existingIdentity) {
			return;
		}

		await this.authIdentityRepository.save(AuthIdentity.create(user, subject, 'chutes'), {
			transaction: false,
		});
	}

	private async syncExistingUser(user: User, username: string) {
		const firstName = this.displayName(username);
		const shouldPromote = this.shouldPromote(username);
		let changed = false;

		if (user.firstName !== firstName) {
			user.firstName = firstName;
			changed = true;
		}

		if (user.lastName !== 'Chutes') {
			user.lastName = 'Chutes';
			changed = true;
		}

		if (shouldPromote && user.role?.slug === GLOBAL_MEMBER_ROLE.slug) {
			user.role = GLOBAL_ADMIN_ROLE;
			changed = true;
		}

		if (!changed) {
			return user;
		}

		return await this.userRepository.save(user, { transaction: false });
	}

	private async upsertManagedCredential(
		user: User,
		subject: string,
		username: string,
		tokenResponse: ChutesTokenResponse,
	) {
		const personalProject = await this.projectRepository.getPersonalProjectForUserOrFail(user.id);
		const existingShare = await this.sharedCredentialsRepository.findOne({
			where: {
				projectId: personalProject.id,
				role: 'credential:owner',
				credentials: {
					type: 'chutesApi',
					name: this.managedCredentialName,
				},
			},
			relations: {
				credentials: true,
			},
		});

		const existingCredential = existingShare?.credentials;
		const existingData = existingCredential
			? ((this.credentialsService.decrypt(existingCredential, true) as Record<string, unknown>) ?? {})
			: {};

		const credentialPayload = {
			name: this.managedCredentialName,
			type: 'chutesApi',
			data: this.buildManagedCredentialData(subject, username, tokenResponse, existingData),
			projectId: personalProject.id,
		};

		if (existingCredential) {
			const encryptedData = this.credentialsService.createEncryptedData({
				id: existingCredential.id,
				name: credentialPayload.name,
				type: credentialPayload.type,
				data: credentialPayload.data,
			});
			await this.credentialsService.update(existingCredential.id, encryptedData);
			return;
		}

		await this.credentialsService.createManagedCredential(credentialPayload, user);
	}

	private async getManagedCredentialForUser(userId: string): Promise<ManagedCredentialLookup> {
		const personalProject = await this.projectRepository.getPersonalProjectForUserOrFail(userId);
		const existingShare = await this.sharedCredentialsRepository.findOne({
			where: {
				projectId: personalProject.id,
				role: 'credential:owner',
				credentials: {
					type: 'chutesApi',
					name: this.managedCredentialName,
				},
			},
			relations: {
				credentials: true,
			},
		});

		const existingCredential = existingShare?.credentials;
		if (!existingCredential) {
			throw new AuthError('No managed Chutes SSO credential is linked to this n8n user');
		}

		const decrypted =
			(this.credentialsService.decrypt(
				existingCredential,
				true,
			) as ChutesManagedCredentialData | null) ?? {};

		return {
			credential: existingCredential,
			data: decrypted,
		};
	}

	private async getAdminFallbackManagedCredential(
		userId: string,
	): Promise<ManagedCredentialLookup | null> {
		const currentUser = await this.userRepository.findOne({
			where: { id: userId },
			relations: ['role'],
		});

		if (
			currentUser?.role?.slug !== GLOBAL_ADMIN_ROLE.slug &&
			currentUser?.role?.slug !== 'global:owner'
		) {
			return null;
		}

		const credentialShares = await this.sharedCredentialsRepository.find({
			where: {
				role: 'credential:owner',
				credentials: {
					type: 'chutesApi',
					name: this.managedCredentialName,
				},
			},
			relations: {
				credentials: true,
			},
		});

		const managedCredential = credentialShares
			.map((share) => share.credentials)
			.filter((credential): credential is NonNullable<typeof credential> => Boolean(credential));

		if (managedCredential.length !== 1) {
			return null;
		}

		const decrypted =
			(this.credentialsService.decrypt(
				managedCredential[0],
				true,
			) as ChutesManagedCredentialData | null) ?? {};

		return {
			credential: managedCredential[0],
			data: decrypted,
		};
	}

	private async refreshManagedCredential(
		managedCredential: ManagedCredentialLookup,
	): Promise<ManagedCredentialLookup> {
		const refreshToken = managedCredential.data.refreshToken?.trim();
		if (!refreshToken) {
			throw new AuthError('The managed Chutes SSO credential is missing a refresh token');
		}

		const tokenResponse = await this.refreshAccessToken(refreshToken);
		const updatedData = this.buildManagedCredentialData(
			managedCredential.data.chutesSubject ?? '',
			managedCredential.data.chutesUsername ?? 'Chutes',
			tokenResponse,
			managedCredential.data as Record<string, unknown>,
		);

		const encryptedData = this.credentialsService.createEncryptedData({
			id: managedCredential.credential.id,
			name: managedCredential.credential.name,
			type: managedCredential.credential.type,
			data: updatedData,
		});
		await this.credentialsService.update(managedCredential.credential.id, encryptedData);

		return {
			credential: managedCredential.credential,
			data: updatedData,
		};
	}

	private buildManagedCredentialData(
		subject: string,
		username: string,
		tokenResponse: ChutesTokenResponse,
		existingData: Record<string, unknown>,
	) {
		return {
			authType: 'sso',
			apiKey: '',
			environment:
				existingData.environment === 'sandbox' || existingData.environment === 'production'
					? existingData.environment
					: 'production',
			customUrl: typeof existingData.customUrl === 'string' ? existingData.customUrl : '',
			sessionToken: tokenResponse.access_token ?? '',
			refreshToken:
				tokenResponse.refresh_token ??
				(typeof existingData.refreshToken === 'string' ? existingData.refreshToken : ''),
			tokenExpiresAt:
				typeof tokenResponse.expires_in === 'number'
					? new Date(Date.now() + tokenResponse.expires_in * 1000).toISOString()
					: '',
			grantedScopes: this.normalizeGrantedScopes(
				tokenResponse.scope,
				typeof existingData.grantedScopes === 'string' ? existingData.grantedScopes : '',
			),
			chutesSubject: subject,
			chutesUsername: username,
		};
	}

	private normalizeGrantedScopes(scope: string | undefined, fallback: string) {
		const normalized = (scope ?? '')
			.split(/\s+/)
			.map((value) => value.trim())
			.filter(Boolean)
			.join(' ');

		if (normalized) {
			return normalized;
		}

		return fallback.trim();
	}

	private async fetchAccountBundle(sessionToken?: string) {
		const token = sessionToken?.trim();
		if (!token) {
			throw new AuthError('The managed Chutes SSO credential is missing a session token');
		}

		const config = {
			headers: {
				Authorization: `Bearer ${token}`,
			},
			validateStatus: () => true,
		};

		const [accountResponse, quotasResponse, liveQuotaResponse] = await Promise.all([
			axios.get<ChutesAccount>(`${this.idpBaseUrl}/users/me`, config),
			axios.get<ChutesQuotaItem[]>(`${this.idpBaseUrl}/users/me/quotas`, config),
			axios.get<ChutesLiveQuota>(`${this.idpBaseUrl}/users/me/quota_usage/h`, config),
		]);

		for (const response of [accountResponse, quotasResponse, liveQuotaResponse]) {
			if (response.status === 401) {
				throw new ChutesAccountUnauthorizedError('Unauthorized');
			}
			if (response.status < 200 || response.status >= 300) {
				throw new AuthError('Failed to fetch Chutes account data');
			}
		}

		return {
			account: accountResponse.data ?? {},
			quotas: quotasResponse.data ?? [],
			liveQuota: liveQuotaResponse.data ?? {},
		};
	}

	private buildAccountSummary(
		user: Pick<User, 'email' | 'firstName'>,
		account: ChutesAccount,
		quotas: ChutesQuotaItem[],
		liveQuota: ChutesLiveQuota,
	) {
		const permissionsBitmask = Number(account.permissions_bitmask ?? 0);
		const dailyQuota = this.extractDailyQuota(quotas);
		const quotaLimit = Number(liveQuota.quota ?? dailyQuota ?? 0);
		const quotaUsed = Number(liveQuota.used ?? 0);
		const quotaRemaining = Math.max(quotaLimit - quotaUsed, 0);
		const quotaPercentage = quotaLimit > 0 ? Math.min((quotaUsed / quotaLimit) * 100, 100) : 0;
		const tier =
			permissionsBitmask === 19
				? 'admin'
				: permissionsBitmask !== 0
					? 'standard'
					: this.getTierFromQuota(dailyQuota);

		return {
			username:
				account.username?.trim() ||
				user.firstName?.trim() ||
				user.email.split('@', 1)[0] ||
				'Chutes User',
			avatarUrl: account.logo?.trim() || null,
			tier,
			tierLabel: this.getTierLabel(tier, permissionsBitmask),
			balanceUsd: Number(Number(account.balance ?? 0).toFixed(2)),
			quota: {
				used: Number(quotaUsed.toFixed(2)),
				limit: Number(quotaLimit.toFixed(2)),
				remaining: Number(quotaRemaining.toFixed(2)),
				percentage: Number(quotaPercentage.toFixed(2)),
			},
			links: {
				accountUrl: 'https://chutes.ai/app/api/billing-balance#daily-quota-usage',
				homeUrl: 'https://chutes.ai/',
				chatUrl: '/chat/',
				n8nUrl: '/n8n/',
			},
		};
	}

	private extractDailyQuota(quotas: ChutesQuotaItem[]) {
		const preferred = quotas.find(
			(item) => item.chute_id === '*' || item.chute_id === 'x' || item.is_default,
		);
		return Number(preferred?.quota ?? quotas[0]?.quota ?? 0);
	}

	private getTierFromQuota(dailyQuota: number) {
		if (dailyQuota < 200) return 'free';
		if (dailyQuota === 200) return 'early-access';
		if (dailyQuota === 300) return 'base';
		if (dailyQuota === 2000) return 'plus';
		if (dailyQuota === 5000) return 'pro';
		if (dailyQuota > 5000) return 'enterprise';
		if (dailyQuota >= 2500) return 'pro';
		if (dailyQuota >= 1000) return 'plus';
		if (dailyQuota >= 250) return 'base';
		if (dailyQuota >= 100) return 'early-access';
		return 'free';
	}

	private getTierLabel(tier: string, permissionsBitmask: number) {
		if (permissionsBitmask === 19) {
			return 'Admin';
		}

		if (permissionsBitmask !== 0) {
			return 'Standard';
		}

		switch (tier) {
			case 'early-access':
				return 'Early-Access';
			case 'base':
				return 'Base';
			case 'plus':
				return 'Plus';
			case 'pro':
				return 'Pro';
			case 'enterprise':
				return 'Enterprise';
			default:
				return 'Flex';
		}
	}

	private assertRequiredScopes(scope?: string) {
		const grantedScopes = new Set(
			(scope ?? '')
				.split(/\s+/)
				.map((value) => value.trim())
				.filter(Boolean),
		);
		const missingScopes = ['chutes:read', 'chutes:invoke'].filter(
			(requiredScope) => !grantedScopes.has(requiredScope),
		);

		if (missingScopes.length === 0) {
			return;
		}

		const grantedList = Array.from(grantedScopes).join(' ') || 'none';
		throw new AuthError(
			`Chutes login did not grant the required scopes (${missingScopes.join(', ')}). Granted scopes: ${grantedList}. Login with Chutes again, and if you already approved this app once, revoke the existing n8n authorization in your Chutes account settings before retrying.`,
		);
	}

	private displayName(username: string) {
		return username.trim().slice(0, 32) || 'Chutes';
	}

	private syntheticEmail(subject: string) {
		const digest = createHash('sha256').update(subject).digest('hex').slice(0, 24);
		return `chutes-${digest}@sso.chutes.local`;
	}

	private shouldPromote(username: string) {
		const allowlist = (process.env.CHUTES_ADMIN_USERNAMES ?? '')
			.split(',')
			.map((entry) => entry.trim().toLowerCase())
			.filter(Boolean);

		return allowlist.includes(username.trim().toLowerCase());
	}

	private normalizeRedirectPath(redirectPath?: string) {
		if (!redirectPath || !redirectPath.startsWith('/') || redirectPath.startsWith('//')) {
			return '/';
		}

		return redirectPath;
	}

	private get callbackUrl() {
		const configuredCallbackUrl = process.env.CHUTES_SSO_CALLBACK_URL?.trim();
		if (configuredCallbackUrl) {
			return configuredCallbackUrl.replace(/\/+$/, '');
		}

		return `${this.urlService.getInstanceBaseUrl()}/${this.globalConfig.endpoints.rest}/sso/chutes/callback`;
	}

	private get clientId() {
		return process.env.CHUTES_OAUTH_CLIENT_ID?.trim() ?? '';
	}

	private get clientSecret() {
		return process.env.CHUTES_OAUTH_CLIENT_SECRET?.trim() ?? '';
	}

	private get idpBaseUrl() {
		return (process.env.CHUTES_IDP_BASE_URL?.trim() || 'https://api.chutes.ai').replace(/\/+$/, '');
	}

	private get managedCredentialName() {
		return 'Chutes SSO';
	}

	private get requestedScopes() {
		return process.env.CHUTES_SSO_SCOPES?.trim() || 'openid profile chutes:read chutes:invoke';
	}

	private isEnabled() {
		return Boolean(this.clientId && this.clientSecret);
	}
}

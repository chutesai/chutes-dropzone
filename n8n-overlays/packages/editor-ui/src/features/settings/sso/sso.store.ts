import type { OidcConfigDto, SamlPreferences } from '@n8n/api-types';
import { computed, ref } from 'vue';
import { defineStore } from 'pinia';
import { useRootStore } from '@n8n/stores/useRootStore';
import * as ssoApi from '@n8n/rest-api-client/api/sso';
import type { SamlPreferencesExtractedData } from '@n8n/rest-api-client/api/sso';
import * as ldapApi from '@n8n/rest-api-client/api/ldap';
import type { LdapConfig } from '@n8n/rest-api-client/api/ldap';
import type { IDataObject } from 'n8n-workflow';
import { UserManagementAuthenticationMethod } from '@/Interface';

export const SupportedProtocols = {
	SAML: 'saml',
	OIDC: 'oidc',
} as const;

export type SupportedProtocolType = (typeof SupportedProtocols)[keyof typeof SupportedProtocols];

export const useSSOStore = defineStore('sso', () => {
	const rootStore = useRootStore();

	const authenticationMethod = ref<UserManagementAuthenticationMethod | undefined>(undefined);
	const selectedAuthProtocol = ref<SupportedProtocolType | undefined>(undefined);

	const chutes = ref({
		loginEnabled: false,
		loginLabel: 'Login with Chutes',
	});

	const isChutesLoginEnabled = computed(() => chutes.value.loginEnabled);

	const showSsoLoginButton = computed(
		() =>
			isChutesLoginEnabled.value ||
			(isSamlLoginEnabled.value &&
				isEnterpriseSamlEnabled.value &&
				isDefaultAuthenticationSaml.value) ||
			(isOidcLoginEnabled.value &&
				isEnterpriseOidcEnabled.value &&
				isDefaultAuthenticationOidc.value),
	);

	const ssoLoginLabel = computed(() =>
		isChutesLoginEnabled.value ? chutes.value.loginLabel : 'Continue with SSO',
	);

	const getSSORedirectUrl = async (existingRedirect?: string) => {
		if (isChutesLoginEnabled.value) {
			const loginUrl = new URL(
				`${window.location.origin}${rootStore.restApiContext.baseUrl}/sso/chutes/login`,
			);
			if (existingRedirect) {
				loginUrl.searchParams.set('redirect', existingRedirect);
			}
			return loginUrl.toString();
		}

		return await ssoApi.initSSO(rootStore.restApiContext, existingRedirect);
	};

	const initialize = (options: {
		authenticationMethod: UserManagementAuthenticationMethod;
		config: {
			chutes?: {
				loginLabel: string;
				loginEnabled: boolean;
			};
			ldap?: Pick<LdapConfig, 'loginLabel' | 'loginEnabled'>;
			saml?: Pick<SamlPreferences, 'loginLabel' | 'loginEnabled'>;
			oidc?: Pick<OidcConfigDto, 'loginEnabled'> & {
				loginUrl?: string;
				callbackUrl?: string;
			};
		};
		features: {
			saml: boolean;
			ldap: boolean;
			oidc: boolean;
		};
	}) => {
		authenticationMethod.value = options.authenticationMethod;

		if (options.config.chutes) {
			chutes.value.loginEnabled = options.config.chutes.loginEnabled;
			chutes.value.loginLabel = options.config.chutes.loginLabel;
		}

		isEnterpriseLdapEnabled.value = options.features.ldap;
		if (options.config.ldap) {
			ldap.value.loginEnabled = options.config.ldap.loginEnabled;
			ldap.value.loginLabel = options.config.ldap.loginLabel;
		}

		isEnterpriseSamlEnabled.value = options.features.saml;
		if (options.config.saml) {
			saml.value.loginEnabled = options.config.saml.loginEnabled;
			saml.value.loginLabel = options.config.saml.loginLabel;
		}

		isEnterpriseOidcEnabled.value = options.features.oidc;
		if (options.config.oidc) {
			oidc.value.loginEnabled = options.config.oidc.loginEnabled;
			oidc.value.loginUrl = options.config.oidc.loginUrl || '';
			oidc.value.callbackUrl = options.config.oidc.callbackUrl || '';
		}
	};

	const saml = ref<Pick<SamlPreferences, 'loginLabel' | 'loginEnabled'>>({
		loginLabel: '',
		loginEnabled: false,
	});

	const samlConfig = ref<SamlPreferences & SamlPreferencesExtractedData>();

	const isSamlLoginEnabled = computed({
		get: () => saml.value.loginEnabled,
		set: (value: boolean) => {
			saml.value.loginEnabled = value;
		},
	});

	const isEnterpriseSamlEnabled = ref(false);

	const isDefaultAuthenticationSaml = computed(
		() => authenticationMethod.value === UserManagementAuthenticationMethod.Saml,
	);

	const getSamlMetadata = async () => await ssoApi.getSamlMetadata(rootStore.restApiContext);

	const getSamlConfig = async () => {
		const config = await ssoApi.getSamlConfig(rootStore.restApiContext);
		samlConfig.value = config;
		saml.value.loginEnabled = config.loginEnabled;
		saml.value.loginLabel = config.loginLabel;
		return config;
	};

	const saveSamlConfig = async (config: Partial<SamlPreferences>) =>
		await ssoApi.saveSamlConfig(rootStore.restApiContext, config);

	const testSamlConfig = async (config: Partial<SamlPreferences>) =>
		await ssoApi.testSamlConfig(rootStore.restApiContext, config);

	const oidc = ref<
		Pick<OidcConfigDto, 'loginEnabled'> & {
			loginUrl?: string;
			callbackUrl?: string;
		}
	>({
		loginUrl: '',
		loginEnabled: false,
		callbackUrl: '',
	});

	const oidcConfig = ref<OidcConfigDto | undefined>();

	const isEnterpriseOidcEnabled = ref(false);

	const getOidcConfig = async () => {
		const config = await ssoApi.getOidcConfig(rootStore.restApiContext);
		oidcConfig.value = config;
		return config;
	};

	const saveOidcConfig = async (config: OidcConfigDto) => {
		const savedConfig = await ssoApi.saveOidcConfig(rootStore.restApiContext, config);
		oidcConfig.value = savedConfig;
		return savedConfig;
	};

	const isOidcLoginEnabled = computed({
		get: () => oidc.value.loginEnabled,
		set: (value: boolean) => {
			oidc.value.loginEnabled = value;
		},
	});

	const isDefaultAuthenticationOidc = computed(
		() => authenticationMethod.value === UserManagementAuthenticationMethod.Oidc,
	);

	const ldap = ref<Pick<LdapConfig, 'loginLabel' | 'loginEnabled'>>({
		loginLabel: '',
		loginEnabled: false,
	});

	const isEnterpriseLdapEnabled = ref(false);

	const isLdapLoginEnabled = computed(() => ldap.value.loginEnabled);

	const ldapLoginLabel = computed(() => ldap.value.loginLabel);

	const getLdapConfig = async () => await ldapApi.getLdapConfig(rootStore.restApiContext);

	const getLdapSynchronizations = async (pagination: { page: number }) =>
		await ldapApi.getLdapSynchronizations(rootStore.restApiContext, pagination);

	const testLdapConnection = async () => await ldapApi.testLdapConnection(rootStore.restApiContext);

	const updateLdapConfig = async (ldapConfig: LdapConfig) =>
		await ldapApi.updateLdapConfig(rootStore.restApiContext, ldapConfig);

	const runLdapSync = async (data: IDataObject) =>
		await ldapApi.runLdapSync(rootStore.restApiContext, data);

	const initializeSelectedProtocol = () => {
		if (selectedAuthProtocol.value) return;

		selectedAuthProtocol.value = isDefaultAuthenticationOidc.value
			? SupportedProtocols.OIDC
			: SupportedProtocols.SAML;
	};

	return {
		chutes,
		isChutesLoginEnabled,
		showSsoLoginButton,
		ssoLoginLabel,
		getSSORedirectUrl,
		initialize,
		selectedAuthProtocol,
		initializeSelectedProtocol,

		saml,
		samlConfig,
		isSamlLoginEnabled,
		isEnterpriseSamlEnabled,
		isDefaultAuthenticationSaml,
		getSamlMetadata,
		getSamlConfig,
		saveSamlConfig,
		testSamlConfig,

		oidc,
		oidcConfig,
		isOidcLoginEnabled,
		isEnterpriseOidcEnabled,
		isDefaultAuthenticationOidc,
		getOidcConfig,
		saveOidcConfig,

		ldap,
		isLdapLoginEnabled,
		isEnterpriseLdapEnabled,
		ldapLoginLabel,
		getLdapConfig,
		getLdapSynchronizations,
		testLdapConnection,
		updateLdapConfig,
		runLdapSync,
	};
});

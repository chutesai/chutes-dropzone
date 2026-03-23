#!/usr/bin/env node

import fs from 'fs';
import path from 'path';

const [, , sourceRoot, overlayRootArg] = process.argv;

if (!sourceRoot || !overlayRootArg) {
	console.error('Usage: apply-n8n-overlay.mjs <source-root> <overlay-root>');
	process.exit(1);
}

const overlayRoot = path.resolve(overlayRootArg);

function filePath(relativePath) {
	return path.join(sourceRoot, ...relativePath.split('/'));
}

function read(relativePath) {
	return fs.readFileSync(filePath(relativePath), 'utf8');
}

function write(relativePath, content) {
	fs.writeFileSync(filePath(relativePath), content, 'utf8');
}

function replaceOnce(content, searchValue, replaceValue, fileLabel) {
	if (!content.includes(searchValue)) {
		throw new Error(`Failed to patch ${fileLabel}: expected block not found`);
	}
	return content.replace(searchValue, replaceValue);
}

function patch(relativePath, replacer) {
	const original = read(relativePath);
	const updated = replacer(original);
	if (updated === original) {
		throw new Error(`Failed to patch ${relativePath}: content unchanged`);
	}
	write(relativePath, updated);
}

function copyOverlayFile(sourceRelativePath, destinationRelativePath) {
	const source = path.join(overlayRoot, sourceRelativePath);
	const destination = filePath(destinationRelativePath);
	fs.mkdirSync(path.dirname(destination), { recursive: true });
	fs.copyFileSync(source, destination);
}

const editorRoot = 'packages/frontend/editor-ui/src';

copyOverlayFile(
	'n8n-overlays/packages/cli/src/controllers/chutes-sso.controller.ts',
	'packages/cli/src/controllers/chutes-sso.controller.ts',
);
copyOverlayFile(
	'n8n-overlays/packages/cli/src/services/chutes-sso.service.ts',
	'packages/cli/src/services/chutes-sso.service.ts',
);
copyOverlayFile(
	'n8n-overlays/packages/editor-ui/src/components/SSOLogin.vue',
	`${editorRoot}/features/settings/sso/components/SSOLogin.vue`,
);
copyOverlayFile(
	'n8n-overlays/packages/editor-ui/src/views/AuthView.vue',
	`${editorRoot}/features/core/auth/views/AuthView.vue`,
);
copyOverlayFile(
	'n8n-overlays/packages/editor-ui/src/views/SigninView.vue',
	`${editorRoot}/features/core/auth/views/SigninView.vue`,
);
copyOverlayFile(
	'n8n-overlays/packages/editor-ui/src/features/settings/sso/sso.store.ts',
	`${editorRoot}/features/settings/sso/sso.store.ts`,
);

patch('packages/cli/src/server.ts', (content) =>
	replaceOnce(
		content,
		"import '@/controllers/auth.controller';\n",
		"import '@/controllers/auth.controller';\nimport '@/controllers/chutes-sso.controller';\n",
		'packages/cli/src/server.ts',
	),
);

patch('packages/@n8n/db/src/entities/types-db.ts', (content) =>
	replaceOnce(
		content,
		"const ALL_AUTH_PROVIDERS = z.enum(['ldap', 'email', 'saml', 'oidc']);",
		"const ALL_AUTH_PROVIDERS = z.enum(['ldap', 'email', 'saml', 'oidc', 'chutes']);",
		'packages/@n8n/db/src/entities/types-db.ts',
	),
);

patch('packages/@n8n/api-types/src/frontend-settings.ts', (content) =>
	replaceOnce(
		replaceOnce(
			content,
			`export type AuthenticationMethod = 'email' | 'ldap' | 'saml' | 'oidc';`,
			`export type AuthenticationMethod = 'email' | 'ldap' | 'saml' | 'oidc' | 'chutes';`,
			'packages/@n8n/api-types/src/frontend-settings.ts',
		),
		`	sso: {
		saml: {
			loginLabel: string;
			loginEnabled: boolean;
		};
		oidc: {
			loginEnabled: boolean;
			loginUrl: string;
			callbackUrl: string;
		};
		ldap: {
			loginLabel: string;
			loginEnabled: boolean;
		};
	};`,
		`	sso: {
		saml: {
			loginLabel: string;
			loginEnabled: boolean;
		};
		oidc: {
			loginEnabled: boolean;
			loginUrl: string;
			callbackUrl: string;
		};
		ldap: {
			loginLabel: string;
			loginEnabled: boolean;
		};
		chutes: {
			loginLabel: string;
			loginEnabled: boolean;
		};
	};`,
		'packages/@n8n/api-types/src/frontend-settings.ts',
	),
);

patch(`${editorRoot}/Interface.ts`, (content) =>
	replaceOnce(
		content,
		`export const enum UserManagementAuthenticationMethod {
	Email = 'email',
	Ldap = 'ldap',
	Saml = 'saml',
	Oidc = 'oidc',
}`,
		`export const enum UserManagementAuthenticationMethod {
	Email = 'email',
	Ldap = 'ldap',
	Saml = 'saml',
	Oidc = 'oidc',
	Chutes = 'chutes',
}`,
		`${editorRoot}/Interface.ts`,
	),
);

patch('packages/cli/src/services/frontend.service.ts', (content) => {
	let updated = replaceOnce(
		content,
		`		const previewMode = process.env.N8N_PREVIEW_MODE === 'true';

		this.settings = {`,
		`		const previewMode = process.env.N8N_PREVIEW_MODE === 'true';
		const chutesSsoEnabled =
			Boolean(process.env.CHUTES_OAUTH_CLIENT_ID?.trim()) &&
			Boolean(process.env.CHUTES_OAUTH_CLIENT_SECRET?.trim());
		const chutesSsoLoginLabel =
			process.env.CHUTES_SSO_LOGIN_LABEL?.trim() || 'Login with Chutes';

		this.settings = {`,
		'packages/cli/src/services/frontend.service.ts',
	);

	updated = replaceOnce(
		updated,
		`			sso: {
				saml: {
					loginEnabled: false,
					loginLabel: '',
				},
				ldap: {
					loginEnabled: false,
					loginLabel: '',
				},
				oidc: {
					loginEnabled: false,
					loginUrl: \`\${instanceBaseUrl}/\${restEndpoint}/sso/oidc/login\`,
					callbackUrl: \`\${instanceBaseUrl}/\${restEndpoint}/sso/oidc/callback\`,
				},
			},`,
		`			sso: {
				saml: {
					loginEnabled: false,
					loginLabel: '',
				},
				ldap: {
					loginEnabled: false,
					loginLabel: '',
				},
				oidc: {
					loginEnabled: false,
					loginUrl: \`\${instanceBaseUrl}/\${restEndpoint}/sso/oidc/login\`,
					callbackUrl: \`\${instanceBaseUrl}/\${restEndpoint}/sso/oidc/callback\`,
				},
				chutes: {
					loginEnabled: chutesSsoEnabled,
					loginLabel: chutesSsoLoginLabel,
				},
			},`,
		'packages/cli/src/services/frontend.service.ts',
	);

	updated = replaceOnce(
		updated,
		`		if (this.licenseState.isOidcLicensed()) {
			Object.assign(this.settings.sso.oidc, {
				loginEnabled: this.globalConfig.sso.oidc.loginEnabled,
			});
		}`,
		`		if (this.licenseState.isOidcLicensed()) {
			Object.assign(this.settings.sso.oidc, {
				loginEnabled: this.globalConfig.sso.oidc.loginEnabled,
			});
		}

		Object.assign(this.settings.sso.chutes, {
			loginEnabled:
				Boolean(process.env.CHUTES_OAUTH_CLIENT_ID?.trim()) &&
				Boolean(process.env.CHUTES_OAUTH_CLIENT_SECRET?.trim()),
			loginLabel: process.env.CHUTES_SSO_LOGIN_LABEL?.trim() || 'Login with Chutes',
		});`,
		'packages/cli/src/services/frontend.service.ts',
	);

	updated = replaceOnce(
		updated,
		`	sso: {
		saml: {
			/** Config flag for SSO button*/
			loginEnabled: FrontendSettings['sso']['saml']['loginEnabled'];
		};
		ldap: {
			/** Config flag for LDAP authentication */
			loginEnabled: FrontendSettings['sso']['ldap']['loginEnabled'];

			/** Customizes login form label (defaults to "Email") */
			loginLabel: FrontendSettings['sso']['ldap']['loginLabel'];
		};
		oidc: {
			/** Config flag for SSO button*/
			loginEnabled: FrontendSettings['sso']['oidc']['loginEnabled'];

			/** Required for OIDC authentication redirect URL */
			loginUrl: FrontendSettings['sso']['oidc']['loginUrl'];
		};
	};`,
		`	sso: {
		saml: {
			/** Config flag for SSO button*/
			loginEnabled: FrontendSettings['sso']['saml']['loginEnabled'];
		};
		ldap: {
			/** Config flag for LDAP authentication */
			loginEnabled: FrontendSettings['sso']['ldap']['loginEnabled'];

			/** Customizes login form label (defaults to "Email") */
			loginLabel: FrontendSettings['sso']['ldap']['loginLabel'];
		};
		oidc: {
			/** Config flag for SSO button*/
			loginEnabled: FrontendSettings['sso']['oidc']['loginEnabled'];

			/** Required for OIDC authentication redirect URL */
			loginUrl: FrontendSettings['sso']['oidc']['loginUrl'];
		};
		chutes: {
			/** Config flag for the native Chutes sign-in button */
			loginEnabled: FrontendSettings['sso']['chutes']['loginEnabled'];

			/** Custom label for the native Chutes sign-in button */
			loginLabel: FrontendSettings['sso']['chutes']['loginLabel'];
		};
	};`,
		'packages/cli/src/services/frontend.service.ts',
	);

	updated = replaceOnce(
		updated,
		`			sso: { saml: ssoSaml, ldap: ssoLdap, oidc: ssoOidc },`,
		`			sso: { saml: ssoSaml, ldap: ssoLdap, oidc: ssoOidc, chutes: ssoChutes },`,
		'packages/cli/src/services/frontend.service.ts',
	);

	updated = replaceOnce(
		updated,
		`			sso: {
				saml: {
					loginEnabled: ssoSaml.loginEnabled,
				},
				ldap: ssoLdap,
				oidc: {
					loginEnabled: ssoOidc.loginEnabled,
					loginUrl: ssoOidc.loginUrl,
				},
			},`,
		`			sso: {
				saml: {
					loginEnabled: ssoSaml.loginEnabled,
				},
				ldap: ssoLdap,
				oidc: {
					loginEnabled: ssoOidc.loginEnabled,
					loginUrl: ssoOidc.loginUrl,
				},
				chutes: ssoChutes,
			},`,
		'packages/cli/src/services/frontend.service.ts',
	);

	return updated;
});

patch(
	`${editorRoot}/features/shared/nodeCreator/composables/useActionsGeneration.ts`,
	(content) =>
		replaceOnce(
			content,
			`function resourceCategories(nodeTypeDescription: INodeTypeDescription): ActionTypeDescription[] {
	const transformedNodes: ActionTypeDescription[] = [];
	const matchedProperties = nodeTypeDescription.properties.filter(
		(property) => property.name === 'resource',
	);
`,
			`function resourceCategories(nodeTypeDescription: INodeTypeDescription): ActionTypeDescription[] {
	if (nodeTypeDescription.name === 'CUSTOM.chutes') {
		return [];
	}

	const transformedNodes: ActionTypeDescription[] = [];
	const matchedProperties = nodeTypeDescription.properties.filter(
		(property) => property.name === 'resource',
	);
`,
			`${editorRoot}/features/shared/nodeCreator/composables/useActionsGeneration.ts`,
		),
);

patch('packages/cli/src/services/user.service.ts', (content) =>
	replaceOnce(
		content,
		`		const providerType = authIdentities?.[0]?.providerType;

		let publicUser: PublicUser = {
			...rest,
			role: role?.slug,
			signInType: providerType ?? 'email',
			isOwner: user.role.slug === 'global:owner',
		};`,
		`		const chutesIdentity = authIdentities?.find((identity) => identity.providerType === 'chutes');
		const providerType = chutesIdentity?.providerType ?? authIdentities?.[0]?.providerType;

		let publicUser: PublicUser = {
			...rest,
			role: role?.slug,
			signInType: providerType ?? 'email',
			isOwner: user.role.slug === 'global:owner',
		};`,
		'packages/cli/src/services/user.service.ts',
	),
);

patch(`${editorRoot}/app/constants/auth.ts`, (content) =>
	replaceOnce(
		content,
		`export const enum SignInType {
	LDAP = 'ldap',
	EMAIL = 'email',
	OIDC = 'oidc',
}`,
		`export const enum SignInType {
	LDAP = 'ldap',
	EMAIL = 'email',
	OIDC = 'oidc',
	CHUTES = 'chutes',
}`,
		`${editorRoot}/app/constants/auth.ts`,
	),
);

patch(`${editorRoot}/features/core/auth/views/SettingsPersonalView.vue`, (content) =>
	replaceOnce(
		content,
		`	const isOidcEnabled =
		ssoStore.isEnterpriseOidcEnabled && currentUser.value?.signInType === 'oidc';
	return isLdapEnabled || isSamlEnabled || isOidcEnabled;`,
		`	const isOidcEnabled =
		ssoStore.isEnterpriseOidcEnabled && currentUser.value?.signInType === 'oidc';
	const isChutesEnabled = currentUser.value?.signInType === 'chutes';
	return isLdapEnabled || isSamlEnabled || isOidcEnabled || isChutesEnabled;`,
		`${editorRoot}/features/core/auth/views/SettingsPersonalView.vue`,
	),
);

patch(`${editorRoot}/features/settings/users/components/SettingsUsersActionsCell.vue`, (content) =>
	replaceOnce(
		content,
		`			v-if="props.data.signInType !== 'ldap' && props.actions.length > 0"`,
		`			v-if="props.data.signInType !== 'ldap' && props.data.signInType !== 'chutes' && props.actions.length > 0"`,
		`${editorRoot}/features/settings/users/components/SettingsUsersActionsCell.vue`,
	),
);

patch('packages/cli/src/credentials-helper.ts', (content) =>
	replaceOnce(
		content,
		`		if (credentialType.preAuthentication) {
			if (typeof credentialType.preAuthentication === 'function') {
				// if the expirable property is empty in the credentials
				// or are expired, call pre authentication method
				// or the credentials are being tested
				if (
					credentials[expirableProperty?.name] === '' ||
					credentialsExpired ||
					isTestingCredentials
				) {
					const output = await credentialType.preAuthentication.call(helpers, credentials);

					// if there is data in the output, make sure the returned
					// property is the expirable property
					// else the database will not get updated
					if (output[expirableProperty.name] === undefined) {
						return undefined;
					}

					if (node.credentials) {
						await this.updateCredentials(
							node.credentials[credentialType.name],
							credentialType.name,
							Object.assign(credentials, output),
						);
						return Object.assign(credentials, output);
					}
				}
			}
		}`,
		`		if (credentialType.preAuthentication) {
			if (typeof credentialType.preAuthentication === 'function') {
				const refreshWindowSeconds = Number.parseInt(
					process.env.N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS ?? '300',
					10,
				);
				const expiresAtRaw =
					typeof credentials.tokenExpiresAt === 'string' ? credentials.tokenExpiresAt : '';
				let credentialsExpiringSoon = false;

				if (expiresAtRaw) {
					const expiresAtTimestamp = Date.parse(expiresAtRaw);
					if (!Number.isNaN(expiresAtTimestamp)) {
						credentialsExpiringSoon =
							expiresAtTimestamp <= Date.now() + Math.max(refreshWindowSeconds, 0) * 1000;
					}
				}

				if (
					credentials[expirableProperty?.name] === '' ||
					credentialsExpired ||
					isTestingCredentials ||
					credentialsExpiringSoon
				) {
					const preAuthenticationCredentials =
						credentialsExpired === true
							? Object.assign({}, credentials, { __n8nForceCredentialRefresh: true })
							: credentials;
					const output = await credentialType.preAuthentication.call(
						helpers,
						preAuthenticationCredentials,
					);

					if (output[expirableProperty.name] === undefined) {
						return undefined;
					}

					if (node.credentials) {
						await this.updateCredentials(
							node.credentials[credentialType.name],
							credentialType.name,
							Object.assign(credentials, output),
						);
						return Object.assign(credentials, output);
					}
				}
			}
		}`,
		'packages/cli/src/credentials-helper.ts',
	),
);

patch('packages/cli/src/credentials/credentials.controller.ts', (content) => {
	let updated = replaceOnce(
		content,
		`import { deepCopy } from 'n8n-workflow';`,
		`import { CredentialTestContext } from 'n8n-core';
import { deepCopy } from 'n8n-workflow';`,
		'packages/cli/src/credentials/credentials.controller.ts',
	);

	updated = replaceOnce(
		updated,
		`import { CredentialsFinderService } from './credentials-finder.service';
import { CredentialsService } from './credentials.service';
import { EnterpriseCredentialsService } from './credentials.service.ee';`,
		`import { CredentialsFinderService } from './credentials-finder.service';
import { CredentialsService } from './credentials.service';
import { EnterpriseCredentialsService } from './credentials.service.ee';

import { CredentialsHelper } from '@/credentials-helper';`,
		'packages/cli/src/credentials/credentials.controller.ts',
	);

	updated = replaceOnce(
		updated,
		`		private readonly eventService: EventService,
		private readonly credentialsFinderService: CredentialsFinderService,
	) {}`,
		`		private readonly eventService: EventService,
		private readonly credentialsFinderService: CredentialsFinderService,
		private readonly credentialsHelper: CredentialsHelper,
	) {}`,
		'packages/cli/src/credentials/credentials.controller.ts',
	);

	updated = replaceOnce(
		updated,
		`		if (mergedCredentials.data) {
			mergedCredentials.data = this.credentialsService.unredact(
				mergedCredentials.data,
				decryptedData,
			);
		}

		return await this.credentialsService.test(req.user.id, mergedCredentials);`,
		`		if (mergedCredentials.data) {
			mergedCredentials.data = this.credentialsService.unredact(
				mergedCredentials.data,
				decryptedData,
			);

			const credentialTestContext = new CredentialTestContext();
			const refreshedCredentials = await this.credentialsHelper.preAuthentication(
				{
					helpers: {
						httpRequest: async (requestOptions) =>
							await credentialTestContext.helpers.request(requestOptions),
					},
				},
				mergedCredentials.data,
				storedCredential.type,
				{
					id: 'temp',
					name: 'Temp-Node',
					type: 'n8n-nodes-base.noOp',
					typeVersion: 1,
					position: [0, 0],
					parameters: { temp: '' },
					credentials: {
						[storedCredential.type]: {
							id: storedCredential.id,
							name: storedCredential.name,
						},
					},
				},
				true,
			);

			if (refreshedCredentials) {
				mergedCredentials.data = refreshedCredentials;
			}
		}

		const testResult = await this.credentialsService.test(req.user.id, mergedCredentials);

		if (mergedCredentials.data) {
			const originalSerialized = JSON.stringify(decryptedData);
			const updatedSerialized = JSON.stringify(mergedCredentials.data);

			if (updatedSerialized !== originalSerialized) {
				const encryptedData = this.credentialsService.createEncryptedData({
					id: storedCredential.id,
					name: storedCredential.name,
					type: storedCredential.type,
					data: mergedCredentials.data,
				});

				await this.credentialsService.update(storedCredential.id, encryptedData);
			}
		}

		return testResult;`,
		'packages/cli/src/credentials/credentials.controller.ts',
	);

	return updated;
});

patch('packages/cli/src/services/credentials-tester.service.ts', (content) =>
	replaceOnce(
		content,
		`		const workflowData = {
			nodes: [node],
			connections: {},
		};`,
		`		if (credentialsDecrypted.data) {
			const credentialTestContext = new CredentialTestContext();
			const refreshedCredentials = await this.credentialsHelper.preAuthentication(
				{
					helpers: {
						httpRequest: async (requestOptions) =>
							await credentialTestContext.helpers.request(requestOptions),
					},
				},
				credentialsDecrypted.data,
				credentialType,
				node,
				false,
			);

			if (refreshedCredentials) {
				credentialsDecrypted.data = refreshedCredentials;
			}
		}

		const workflowData = {
			nodes: [node],
			connections: {},
		};`,
		'packages/cli/src/services/credentials-tester.service.ts',
	),
);

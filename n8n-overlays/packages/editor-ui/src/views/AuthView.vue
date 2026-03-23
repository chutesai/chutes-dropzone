<script setup lang="ts">
import { N8nFormBox, N8nLogo, N8nText } from '@n8n/design-system';

import SSOLogin from '@/features/settings/sso/components/SSOLogin.vue';
import type { FormFieldValueUpdate, IFormBoxConfig } from '@/Interface';
import { useSettingsStore } from '@/app/stores/settings.store';
import type { EmailOrLdapLoginIdAndPassword } from './SigninView.vue';

withDefaults(
	defineProps<{
		form: IFormBoxConfig;
		formLoading?: boolean;
		subtitle?: string;
		withSso?: boolean;
		showPasswordLogin?: boolean;
		passwordLoginToggleLabel?: string;
	}>(),
	{
		formLoading: false,
		withSso: false,
		showPasswordLogin: true,
		passwordLoginToggleLabel: '',
	},
);

const emit = defineEmits<{
	update: [FormFieldValueUpdate];
	submit: [values: EmailOrLdapLoginIdAndPassword];
	secondaryClick: [];
	togglePasswordLogin: [];
}>();

const onUpdate = (e: FormFieldValueUpdate) => {
	emit('update', e);
};

const onSubmit = (data: unknown) => {
	emit('submit', data as EmailOrLdapLoginIdAndPassword);
};

const onSecondaryClick = () => {
	emit('secondaryClick');
};

const onTogglePasswordLogin = () => {
	emit('togglePasswordLogin');
};

const {
	settings: { releaseChannel },
} = useSettingsStore();
</script>

<template>
	<div :class="$style.container">
		<N8nLogo size="large" :release-channel="releaseChannel" />
		<div v-if="subtitle" :class="$style.textContainer">
			<N8nText size="large">{{ subtitle }}</N8nText>
		</div>
		<SSOLogin v-if="withSso" :class="$style.primarySso" />
		<div v-if="!withSso || showPasswordLogin" :class="$style.formContainer">
			<N8nFormBox
				v-bind="form"
				data-test-id="auth-form"
				:button-loading="formLoading"
				@secondary-click="onSecondaryClick"
				@submit="onSubmit"
				@update="onUpdate"
			/>
		</div>
		<div v-else-if="passwordLoginToggleLabel" :class="$style.passwordToggleContainer">
			<button
				type="button"
				data-test-id="toggle-password-login"
				:class="$style.passwordLoginToggle"
				@click="onTogglePasswordLogin"
			>
				{{ passwordLoginToggleLabel }}
			</button>
		</div>
		<div :class="$style.crossAppLinkContainer">
			<a href="/chat/" :class="$style.crossAppLink">Open Chutes Chat</a>
		</div>
	</div>
</template>

<style lang="scss" module>
body {
	background-color: var(--color--background--light-2);
}

.container {
	display: flex;
	align-items: center;
	justify-content: center;
	flex-direction: column;
	min-height: 100vh;
	padding: var(--spacing--3xl) 0;
	box-sizing: border-box;

	> * {
		width: 352px;
	}
}

.textContainer {
	text-align: center;
}

.primarySso {
	margin-top: var(--spacing--l);
}

.formContainer {
	padding-bottom: var(--spacing--xl);
}

.passwordToggleContainer {
	margin-top: var(--spacing--xl);
	padding-bottom: var(--spacing--xl);
	text-align: center;
}

.passwordLoginToggle {
	cursor: pointer;
	border: none;
	background: transparent;
	padding: 0;
	color: var(--color-text-base);
	font: inherit;
	text-decoration: underline;

	&:hover,
	&:focus-visible {
		color: var(--color-primary);
	}
}

.crossAppLinkContainer {
	padding-bottom: var(--spacing--xl);
	text-align: center;
}

.crossAppLink {
	display: inline-flex;
	align-items: center;
	justify-content: center;
	min-height: 40px;
	padding: 0 var(--spacing--m);
	border-radius: var(--border-radius-base);
	background: color-mix(in srgb, var(--color-primary) 12%, white);
	color: var(--color-primary);
	font-weight: var(--font-weight-bold);
	text-decoration: none;
	transition:
		transform 120ms ease,
		background 120ms ease,
		box-shadow 120ms ease;

	&:hover,
	&:focus-visible {
		background: color-mix(in srgb, var(--color-primary) 18%, white);
		box-shadow: 0 8px 24px rgb(0 0 0 / 10%);
		transform: translateY(-1px);
	}
}
</style>

<style lang="scss">
.el-checkbox__label span {
	font-size: var(--font-size-2xs) !important;
}
</style>

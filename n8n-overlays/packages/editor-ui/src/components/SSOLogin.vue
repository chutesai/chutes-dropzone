<script lang="ts" setup>
import { computed } from 'vue';
import { useRoute } from 'vue-router';

import { useToast } from '@/app/composables/useToast';
import { useSSOStore } from '@/features/settings/sso/sso.store';

import { N8nButton } from '@n8n/design-system';

const ssoStore = useSSOStore();
const toast = useToast();
const route = useRoute();

const buttonLabel = computed(() => ssoStore.ssoLoginLabel);

const onSSOLogin = async () => {
	try {
		const redirect = typeof route.query?.redirect === 'string' ? route.query.redirect : '';
		window.location.href = await ssoStore.getSSORedirectUrl(redirect);
	} catch (error) {
		toast.showError(
			error,
			'Error',
			error instanceof Error ? error.message : 'Unable to start sign-in',
		);
	}
};
</script>

<template>
	<div v-if="ssoStore.showSsoLoginButton" :class="$style.ssoLogin">
		<N8nButton type="primary" size="large" :label="buttonLabel" block @click="onSSOLogin" />
	</div>
</template>

<style lang="scss" module>
.ssoLogin {
	display: flex;
	justify-content: center;
	text-align: center;
}
</style>

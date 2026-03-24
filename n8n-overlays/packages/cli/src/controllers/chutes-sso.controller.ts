import type { User } from '@n8n/db';
import { GlobalConfig } from '@n8n/config';
import { Time } from '@n8n/constants';
import { Get, RestController } from '@n8n/decorators';
import { Request, Response } from 'express';

import { AuthService } from '@/auth/auth.service';
import { EventService } from '@/events/event.service';
import { AuthlessRequest } from '@/requests';
import { ChutesSsoService } from '@/services/chutes-sso.service';
import { UrlService } from '@/services/url.service';

const CHUTES_FLOW_COOKIE = 'n8n-chutes-sso-flow';

type ChutesLoginQuery = {
	redirect?: string;
};

type ChutesCallbackQuery = {
	code?: string;
	state?: string;
};

type AuthenticatedUserRequest = Request & {
	user: User;
};

@RestController('/sso/chutes')
export class ChutesSsoController {
	constructor(
		private readonly authService: AuthService,
		private readonly chutesSsoService: ChutesSsoService,
		private readonly eventService: EventService,
		private readonly urlService: UrlService,
		private readonly globalConfig: GlobalConfig,
	) {}

	@Get('/login', { skipAuth: true })
	async login(req: AuthlessRequest<{}, {}, {}, ChutesLoginQuery>, res: Response) {
		const referer = typeof req.headers.referer === 'string' ? req.headers.referer : undefined;
		const redirect = typeof req.query.redirect === 'string' ? req.query.redirect : referer;
		const { authorizationUrl, flowToken } = this.chutesSsoService.beginLogin(redirect);
		const { samesite, secure } = this.globalConfig.auth.cookie;

		res.cookie(CHUTES_FLOW_COOKIE, flowToken, {
			httpOnly: true,
			sameSite: samesite,
			secure,
			maxAge: 10 * Time.minutes.toMilliseconds,
		});

		return res.redirect(authorizationUrl);
	}

	@Get('/callback', { skipAuth: true })
	async callback(req: AuthlessRequest<{}, {}, {}, ChutesCallbackQuery>, res: Response) {
		try {
			const code = typeof req.query.code === 'string' ? req.query.code : undefined;
			const state = typeof req.query.state === 'string' ? req.query.state : undefined;
			const flowToken =
				typeof req.cookies?.[CHUTES_FLOW_COOKIE] === 'string'
					? req.cookies[CHUTES_FLOW_COOKIE]
					: undefined;

			const { user, redirectPath } = await this.chutesSsoService.completeLogin({
				code,
				state,
				flowToken,
			});

			res.clearCookie(CHUTES_FLOW_COOKIE);
			this.authService.issueCookie(res, user, true, req.browserId);
			this.eventService.emit('user-logged-in', {
				user,
				authenticationMethod: 'chutes',
			});

			return res.redirect(this.urlService.getInstanceBaseUrl() + redirectPath);
		} catch (error) {
			res.clearCookie(CHUTES_FLOW_COOKIE);
			this.eventService.emit('user-login-failed', {
				authenticationMethod: 'chutes',
				userEmail: 'unknown',
				reason: (error as Error).message,
			});
			return res.redirect(this.urlService.getInstanceBaseUrl() + '/signin?chutesError=1');
		}
	}

	@Get('/account-summary')
	async accountSummary(req: AuthenticatedUserRequest, res: Response) {
		res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, private');
		res.setHeader('Pragma', 'no-cache');
		res.setHeader('Expires', '0');
		return await this.chutesSsoService.getAccountSummaryForUser(req.user);
	}
}

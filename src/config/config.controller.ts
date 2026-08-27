import { Controller, Get } from '@nestjs/common';

export interface ApplicationConfig {
  environment: string;
  message: string;
  featureExperimental: boolean;
}

@Controller('config')
export class ConfigController {
  @Get()
  getConfig(): ApplicationConfig {
    return {
      environment: process.env.APP_ENV ?? 'local',
      message: process.env.APP_MESSAGE ?? 'KubeScope - Local Development',
      featureExperimental:
        (process.env.FEATURE_EXPERIMENTAL ?? 'false').toLowerCase() === 'true',
    };
  }
}

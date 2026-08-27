import { Module } from '@nestjs/common';
import { APP_INTERCEPTOR } from '@nestjs/core';
import { ConfigController } from './config/config.controller';
import { HealthController } from './health/health.controller';
import { MetricsController } from './metrics/metrics.controller';
import { MetricsInterceptor } from './metrics/metrics.interceptor';
import { MetricsService } from './metrics/metrics.service';
import { RuntimeController } from './runtime/runtime.controller';
import { RuntimeService } from './runtime/runtime.service';

@Module({
  controllers: [
    HealthController,
    RuntimeController,
    ConfigController,
    MetricsController,
  ],
  providers: [
    RuntimeService,
    MetricsService,
    {
      provide: APP_INTERCEPTOR,
      useClass: MetricsInterceptor,
    },
  ],
})
export class AppModule {}

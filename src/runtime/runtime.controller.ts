import { Controller, Get } from '@nestjs/common';
import { RuntimeInfo, RuntimeService } from './runtime.service';

@Controller('info')
export class RuntimeController {
  constructor(private readonly runtime: RuntimeService) {}

  @Get()
  getInfo(): RuntimeInfo {
    return this.runtime.getInfo();
  }
}

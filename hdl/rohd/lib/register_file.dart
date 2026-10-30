import 'package:rohd/rohd.dart';
import 'constants.dart';

class RegisterFile extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');
  Logic get rAddrA => input('rAddrA');
  Logic get rAddrB => input('rAddrB');
  Logic get wAddr => input('wAddr');
  Logic get wData => input('wData');
  Logic get wEn => input('wEn');
  Logic get xchgEn => input('xchgEn');
  Logic get xchgAllEn => input('xchgAllEn');
  Logic get xchgMostEn => input('xchgMostEn');
  Logic get xchgRegIdx => input('xchgRegIdx');

  Logic get rDataA => output('rDataA');
  Logic get rDataB => output('rDataB');

  RegisterFile({
    required Logic clk,
    required Logic reset,
    required Logic rAddrA,
    required Logic rAddrB,
    required Logic wAddr,
    required Logic wData,
    required Logic wEn,
    required Logic xchgEn,
    required Logic xchgAllEn,
    required Logic xchgMostEn,
    required Logic xchgRegIdx,
    super.name = 'register_file',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('rAddrA', rAddrA, width: ParticleWidths.regAddr);
    addInput('rAddrB', rAddrB, width: ParticleWidths.regAddr);
    addInput('wAddr', wAddr, width: ParticleWidths.regAddr);
    addInput('wData', wData, width: ParticleWidths.word);
    addInput('wEn', wEn);
    addInput('xchgEn', xchgEn);
    addInput('xchgAllEn', xchgAllEn);
    addInput('xchgMostEn', xchgMostEn);
    addInput('xchgRegIdx', xchgRegIdx, width: ParticleWidths.regAddr);

    addOutput('rDataA', width: ParticleWidths.word);
    addOutput('rDataB', width: ParticleWidths.word);
  }
}

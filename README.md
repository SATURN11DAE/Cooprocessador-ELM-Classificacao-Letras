# Array Sistólico para Aceleração de ELM em FPGA

Módulo em Verilog de um **array sistólico 1-D parametrizável** que acelera o produto matriz × vetor da inferência de uma **Extreme Learning Machine (ELM)** para classificação de dígitos (MNIST 28×28) na **DE1-SoC (Cyclone V)**.

> **Status:** simulado e verificado contra um golden model em testbench. Ainda **não** sintetizado no Quartus e ainda **não** integrado à FSM completa do ELM (ver [Limitações e próximos passos](#limitações-e-próximos-passos)).

---

## Sumário

1. [Problema e requisitos](#1-problema-e-requisitos)
2. [Ideia: o que é um array sistólico](#2-ideia-o-que-é-um-array-sistólico)
3. [Arquitetura](#3-arquitetura)
4. [Interface dos módulos](#4-interface-dos-módulos)
5. [Como integrar ao co-processador](#5-como-integrar-ao-co-processador)
6. [Ambiente e instalação](#6-ambiente-e-instalação)
7. [Testes](#7-testes)
8. [Resultados e análise](#8-resultados-e-análise)
9. [Limitações e próximos passos](#limitações-e-próximos-passos)
10. [Estrutura do repositório](#estrutura-do-repositório)
11. [Referências](#referências)

---

## 1. Problema e requisitos

A ELM do projeto tem três etapas computacionais:

| Etapa | Operação | Dimensões | MACs |
|---|---|---|---|
| Camada oculta | `h = tanh(W_in · x + b)` | `W_in`: 128×784, `x`: 784 | 100.352 |
| Camada de saída | `y = β · h` | `β`: 10×128, `h`: 128 | 1.280 |
| Predição | `pred = argmax(y)` | 10 valores | – |

Quase todo o custo está nos **101.632 MACs** das duas camadas. Com um único MAC, isso são ~100 mil ciclos por imagem.

**Requisitos atendidos por este módulo**

- Valores em ponto fixo **Q4.12** (16 bits, com sinal).
- Datapath de multiplica-acumula (cada PE é um MAC).
- Pesos lidos de blocos de memória, com estratégia de bancos (seção 5).
- Parametrizável: `P = 1` reproduz o MAC tradicional, o que permite comparar as duas arquiteturas.

---

## 2. Ideia: o que é um array sistólico

Em vez de um MAC lendo toda a matriz, usamos vários MACs (PEs) em fila. O dado `x` **caminha de PE em PE, um por ciclo**, e cada PE acumula o resultado de **um neurônio**:

```
 x ──►[PE0]──►[PE1]──►[PE2]── ... ──►[PE P-1]
        ▲       ▲       ▲               ▲
       w[0]    w[1]    w[2]           w[P-1]
      (sem    (atraso (atraso         (atraso
      atraso) 1 ciclo) 2 ciclos)      P-1 ciclos)
```

Como `x[k]` chega ao PE `j` com `j` ciclos de atraso, o peso `W[j][k]` também é atrasado em `j` ciclos (*skew*). Com 3 PEs:

```
ciclo:    0     1     2     3     4
PE0 vê:  x0    x1    x2
PE1 vê:        x0    x1    x2
PE2 vê:              x0    x1    x2
```

**Vantagem em relação ao broadcast de `x` para todos os MACs:** cada PE só se conecta ao vizinho, então os fios são curtos e o Fmax tende a ser maior.

**Observação honesta:** como a inferência processa **uma imagem por vez** (matriz × vetor), um array 2-D não traria ganho. O ganho aqui vem de `P` neurônios em paralelo. Um array 2-D só compensaria processando várias imagens em lote.

---

## 3. Arquitetura

### 3.1 Visão geral

```
            ┌──────────────────────── MatPreparar ────────────────────────┐
 start ───► │  contador k  ──► k_idx ──► (RAM de x)  ──┐                    │
 K ───────► │      │                     (RAM de W)  ──┼─► systolic_array   │ ──► acc_flat
            │      └─► valid/first (atrasados 1 ciclo) ┘     (P × pe)       │ ──► done
            └───────────────────────────────────────────────────────────────┘
```

| Módulo | Arquivo | Função |
|---|---|---|
| `pe` | `pe.v` | MAC com repasse de `x`, `valid` e `first` ao vizinho |
| `systolic_array` | `systolic_array.v` | `P` PEs em fila + linhas de atraso (skew) dos pesos |
| `MatPreparar` | `MatPreparar.v` | Contador `k`, alinhamento da latência da RAM, drenagem do pipeline e sinal `done` |
| `tb_systolic` | `tb_systolic.v` | Testbench com golden model |

### 3.2 Formatos numéricos

| Sinal | Formato | Largura |
|---|---|---|
| `x`, `w` | Q4.12 com sinal | 16 bits |
| `x · w` | Q8.24 com sinal | 32 bits |
| `acc` | Q8.24 com sinal | 40 bits |

O acumulador tem 8 bits de folga para somar até 784 produtos sem overflow. A conversão de volta para Q4.12 (`acc >>> 12` com saturação) é feita **fora** do array, no pós-processamento.

### 3.3 Linha do tempo de uma tile

```
cnt:      0  1  2 ... K-1  K  K+1 ...  K+P
leitura:  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓            (endereços k = 0..K-1 vão para as RAMs)
array:       ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓         (dados entram 1 ciclo depois)
drenagem:                  ░░░░░░░░░ (último dado atravessa os P PEs)
                                  └► done
```

Uma *tile* calcula `P` neurônios. Duração medida em simulação: **K + P + 1 ciclos** (801 para K = 784, P = 16).

---

## 4. Interface dos módulos

### 4.1 Parâmetros

| Parâmetro | Padrão | Descrição |
|---|---|---|
| `DW` | 16 | Largura dos dados (Q4.12) |
| `AW` | 40 | Largura do acumulador |
| `P` | 16 | Número de PEs (neurônios em paralelo) |

### 4.2 `MatPreparar`

| Porta | Dir. | Largura | Descrição |
|---|---|---|---|
| `clk`, `rst` | in | 1 | Clock e reset síncrono |
| `start` | in | 1 | Pulso de 1 ciclo para iniciar a tile |
| `K` | in | 16 | Tamanho do vetor (784 ou 128) |
| `busy` | out | 1 | 1 enquanto calcula |
| `done` | out | 1 | Pulso de 1 ciclo: `acc_flat` está pronto |
| `k_idx` | out | 16 | Índice do elemento atual (endereço nas RAMs) |
| `x_data` | in | 16 | `x[k_idx]`, chega **1 ciclo depois** |
| `w_data_flat` | in | `P·DW` | `W[0..P-1][k]`, chega **1 ciclo depois** |
| `acc_flat` | out | `P·AW` | `acc_flat[j*AW +: AW]` = resultado do neurônio `j` |

Memórias esperadas: RAM **síncrona** com leitura em 1 ciclo (comportamento padrão dos blocos M10K).

---

## 5. Como integrar ao co-processador

### 5.1 Organização da memória de pesos

Para entregar `P` pesos por ciclo, `W_in` fica em **`P` bancos** (um bloco de memória por PE). O banco `j` guarda as linhas `tile·P + j`:

```
endereço no banco j  =  tile * K + k_idx
conteúdo             =  W[tile*P + j][k_idx]
```

Todos os bancos são lidos com o **mesmo endereço**; o skew é feito dentro do array.

### 5.2 Sequência da FSM do ELM

1. **Camada oculta** (`K = 784`): para `tile = 0 .. 127/P`, dar `start`, esperar `done`, ler `acc_flat`.
2. **Pós-processamento sequencial e compartilhado** (fora do array): `acc >>> 12`, saturação para 16 bits, soma de `b[n]`, LUT de `tanh`, gravação em `h`.
3. **Camada de saída** (`K = 128`): reutiliza o mesmo array com `x = h` e `W = β`. Com `P = 16`, apenas 10 PEs são úteis (1 tile).
4. **Argmax** sobre os 10 resultados.

> Como `argmax` é monotônico, o `tanh` da camada de saída pode ser dispensado. Confirme se o golden model fornecido pelo professor o aplica.

---

## 6. Ambiente e instalação

### 6.1 Software utilizado

| Ferramenta | Versão | Uso |
|---|---|---|
| Icarus Verilog | 12.0 | Simulação |
| Ubuntu | 24.04 | Sistema onde as simulações foram rodadas |
| Quartus Prime | _a preencher_ | Síntese e uso de recursos |
| ModelSim / Questa | _a preencher_ | (opcional) simulação com waveform |

### 6.2 Hardware alvo

- Placa: **DE1-SoC** (FPGA Cyclone V SoC `5CSEMA5F31C6`)
- 87 blocos DSP, memórias M10K (verificar a disponibilidade no seu projeto)

### 6.3 Instalação do simulador

```bash
# Ubuntu / Debian
sudo apt update
sudo apt install iverilog

iverilog -V        # confirma a versão
```

---

## 7. Testes

O testbench `tb_systolic.v` roda duas tiles com dados aleatórios e compara **cada um dos `P` acumuladores** com um golden model (soma de produtos em inteiros de 64 bits):

| Teste | `K` | Equivale a |
|---|---|---|
| 1 | 784 | camada oculta (`W_in · x`) |
| 2 | 128 | camada de saída (`β · h`) |

### Executando

```bash
cd systolic
iverilog -g2005 -Wall -o sim pe.v systolic_array.v MatPreparar.v tb_systolic.v
vvp sim
```

### Saída esperada

```
K= 784 | ~801 ciclos | erros=0 | PASSOU
K= 128 | ~145 ciclos | erros=0 | PASSOU
-------------------------------------
TUDO CERTO
```

### Observações sobre o testbench

- Estímulos são aplicados na borda de **descida** do clock para evitar corridas com o DUT.
- As memórias são **comportamentais** (leitura síncrona de 1 ciclo). Ainda precisam ser trocadas pelas RAMs reais (`altsyncram`/IP do Quartus) carregadas com os pesos fornecidos.
- Os dados são aleatórios; falta validar com os **vetores de teste e o golden model do professor**.

---

## 8. Resultados e análise

### 8.1 Latência (simulação)

| Camada | `K` | Tiles | Ciclos por tile | Ciclos totais |
|---|---|---|---|---|
| Oculta (P = 16) | 784 | 8 | ~801 | ~6.408 |
| Saída (P = 16) | 128 | 1 | ~145 | ~145 |
| **Total** | | | | **~6.553** |

Fórmula: `ciclos ≈ ceil(N_neuronios / P) · (K + P + 1)`.

### 8.2 Comparação com o MAC único (P = 1)

| Arquitetura | MACs/ciclo | Ciclos (camada oculta) | Speedup |
|---|---|---|---|
| MAC sequencial (P = 1) | 1 | ≈ 128 · 785 ≈ 100 mil | 1× |
| Array sistólico (P = 16) | 16 | ≈ 6,4 mil | **≈ 15,7×** |

O speedup fica abaixo de 16× por causa do custo de preencher e drenar o pipeline em cada tile (`P + 1` ciclos). Esses números **não incluem** pós-processamento (tanh, bias, argmax) nem o carregamento de memórias.

### 8.3 Uso de recursos

| Recurso | `P = 16` |
|---|---|
| LUT / ALM | _a medir no Quartus_ |
| Registradores | _a medir_ |
| DSP | esperado ≈ 16 (um 16×16 por PE) |
| BRAM (M10K) | _a medir_ (`W_in` ≈ 200 KB) |
| Fmax | _a medir_ |

### 8.4 Análise

- O ganho de latência é quase linear em `P`; o custo é `P` multiplicadores e `P` bancos de memória.
- A **largura de banda de memória** é o limite real: o array precisa de `P` pesos por ciclo, o que exige os `P` bancos.
- Os `P + 1` ciclos de drenagem por tile poderiam ser escondidos iniciando a próxima tile antes de terminar a atual (hoje elas não se sobrepõem).

---

## Limitações e próximos passos

- [ ] Síntese no Quartus e levantamento de LUT/FF/DSP/BRAM/Fmax.
- [ ] Substituir as memórias comportamentais por RAMs reais com `W_in`, `b` e `β` carregados.
- [ ] FSM completa do ELM em volta do `MatPreparar` (tiles, bias, LUT de tanh, argmax).
- [ ] Validar com os vetores de teste e o golden model do professor.
- [ ] Mapa de registradores (CTRL / STATUS / IMG / RESULT / CYCLES) e integração com o HPS.
- [ ] Sobrepor tiles para esconder a latência de drenagem.
- [ ] Explorar valores de `P` (1, 2, 4, 8, 16, 32) e comparar área × desempenho.

---

## Estrutura do repositório

```
systolic/
├── pe.v                 # Processing Element (MAC + repasse)
├── systolic_array.v     # Array de P PEs + skew dos pesos
├── MatPreparar.v      # Controle de uma tile (contador, latência, done)
├── tb_systolic.v        # Testbench com golden model
└── README.md
```

---

## Referências

- Enunciado: *Problema 2026.1 – TEC 499 MI Sistemas Digitais*, UEFS.
- Huang, G.-B. et al. *Extreme learning machine: algorithm, theory and applications.*
- Kung, H. T. *Why systolic architectures?* IEEE Computer, 1982.
- Intel/Altera: *Cyclone V Device Handbook* e *DE1-SoC User Manual* (FPGA Academy).

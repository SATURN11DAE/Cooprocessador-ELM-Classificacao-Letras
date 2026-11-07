//  systolic_array.v  -  Array sistólico 1-D com P processadores (PEs)
//
//  Calcula P produtos escalares AO MESMO TEMPO:
//
//        acc[j] = Σ  x[k] * W[j][k]          (j = 0 .. P-1)
//                 k
//
//  Estrutura (x "caminha" para a direita, 1 PE por ciclo):
//
//   x ──►[PE0]──►[PE1]──►[PE2]── ... ──►[PE P-1]
//          ▲       ▲       ▲               ▲
//          │       │       │               │
//         w[0]   w[1]    w[2]           w[P-1]
//        (sem   (atraso  (atraso        (atraso
//        atraso) 1 ciclo) 2 ciclos)     P-1 ciclos)
//
//  Por que o atraso nos pesos ("skew")?
//      x[k] chega ao PE j com j ciclos de atraso. O peso W[j][k] precisa
//      chegar no MESMO instante, então atrasamos w[j] em j ciclos.
//
//  Exemplo com 3 PEs (tempo em ciclos, x0 entra no ciclo 0):
//
//      ciclo:    0     1     2     3     4
//      PE0 vê:  x0    x1    x2
//      PE1 vê:        x0    x1    x2
//      PE2 vê:              x0    x1    x2
//
//  Interface dos pesos: w_flat é um barramento largo com os P pesos juntos.
//      w_flat[j*DW +: DW]  =  W[j][k]   (peso do PE j para o x atual)

`timescale 1ns/1ps

module SystolicArray #(
    parameter DW = 16,          // largura dos dados (Q4.12)
    parameter AW = 40,          // largura dos acumuladores
    parameter P  = 16           // número de PEs (neurônios em paralelo)
)(
    input  wire                 clk,
    input  wire                 rst,

    // ---- Entrada: um elemento de x por ciclo ----
    input  wire                 in_valid,
    input  wire                 in_first,       // 1 no primeiro elemento (k = 0)
    input  wire signed [DW-1:0] x,

    // ---- Pesos: um por PE, todos para o mesmo k ----
    input  wire [P*DW-1:0]      w_flat,

    // ---- Saída: acumulador de cada PE, empacotados ----
    //      acc_flat[j*AW +: AW] = resultado do neurônio j
    output wire [P*AW-1:0]      acc_flat
);

    //  "Fios" entre os PEs: o PE j lê o índice j e escreve no índice j+1.
    wire signed [DW-1:0] x_link     [0:P];
    wire                 valid_link [0:P];
    wire                 first_link [0:P];

    assign x_link[0]     = x;
    assign valid_link[0] = in_valid;
    assign first_link[0] = in_first;

    //  Gera P PEs, cada um com sua linha de atraso (skew) no peso
    genvar j;
    generate
        for (j = 0; j < P; j = j + 1) begin : g_pe

            // Peso deste PE, "cru" (sem atraso)
            wire signed [DW-1:0] w_cru = w_flat[j*DW +: DW];
            // Peso já atrasado de j ciclos (é este que entra no PE)
            wire signed [DW-1:0] w_atrasado;

            if (j == 0) begin : g_sem_atraso
                // PE0 não precisa esperar ninguém
                assign w_atrasado = w_cru;
            end

            else begin : g_com_atraso
                // Registradores em fila: w_cru -> sh[0] -> sh[1] -> ... -> sh[j-1]
                reg signed [DW-1:0] sh [0:j-1];
                integer i;
                always @(posedge clk) begin
                    sh[0] <= w_cru;
                    for (i = 1; i < j; i = i + 1)
                        sh[i] <= sh[i-1];
                end
                assign w_atrasado = sh[j-1];
            end

            // O PE em si
            ProcessingElement #(.DW(DW), .AW(AW)) u_pe (
                .clk       (clk),
                .rst       (rst),
                .v_in      (valid_link[j]),
                .first_in  (first_link[j]),
                .x_in      (x_link[j]),
                .w_in      (w_atrasado),
                .v_out     (valid_link[j+1]),
                .first_out (first_link[j+1]),
                .x_out     (x_link[j+1]),
                .acc       (acc_flat[j*AW +: AW])
            );
        end
    endgenerate
endmodule

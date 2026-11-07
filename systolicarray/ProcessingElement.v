//  pe.v  -  Processing Element (PE) do array sistólico
//
//  Um PE é um MAC (multiplica-acumula) que também "repassa" o dado x ao vizinho.
//
//                 x_in ──►┌──────────────────┐──► x_out   (x atrasado 1 ciclo)
//                         │   acc += x * w   │
//                  w_in ─►│                  │
//                         └────────┬─────────┘
//                                  ▼
//                                 acc   (resultado de UM neurônio)
//
//  O que cada PE faz a cada ciclo em que v_in = 1:
//      1) multiplica  x_in * w_in
//      2) soma no acumulador  (ou SUBSTITUI o acumulador, se first_in = 1)
//      3) passa x, v e first para o PE seguinte
//
//  Formatos numéricos:
//      x, w   : Q4.12 com sinal (16 bits)
//      x * w  : Q8.24 com sinal (32 bits)
//      acc    : Q8.24 com sinal (40 bits) -> 8 bits de folga p/ somar 784 termos

`timescale 1ns/1ps

module ProcessingElement #(
    parameter DW = 16,          // largura dos dados (Q4.12)
    parameter AW = 40           // largura do acumulador
)(
    input  wire                 clk,
    input  wire                 rst,

    // ---- Entradas (vindas do PE anterior / da memória de pesos) ----
    input  wire                 v_in,       // 1 = x_in e w_in são válidos
    input  wire                 first_in,   // 1 = primeiro elemento da soma
    input  wire signed [DW-1:0] x_in,
    input  wire signed [DW-1:0] w_in,

    // ---- Saídas (vão para o PE seguinte) ----
    output reg                  v_out,
    output reg                  first_out,
    output reg  signed [DW-1:0] x_out,

    // ---- Resultado deste PE ----
    output reg  signed [AW-1:0] acc
);

    // Produto combinacional: Q4.12 * Q4.12 = Q8.24
    wire signed [2*DW-1:0] produto = x_in * w_in;

    always @(posedge clk) begin
        if (rst) begin
            v_out     <= 1'b0;
            first_out <= 1'b0;
            x_out     <= {DW{1'b0}};
            acc       <= {AW{1'b0}};
        end
        else begin
            // 1) Repasse para o vizinho (sempre, 1 ciclo de atraso)
            v_out     <= v_in;
            first_out <= first_in;
            x_out     <= x_in;

            // 2) Acumulação (só quando o dado é válido)
            if (v_in) begin
                if (first_in) acc <= produto;          // começa uma nova soma
                else          acc <= acc + produto;    // continua a soma
            end
        end
    end

endmodule

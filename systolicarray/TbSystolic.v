//  tb_systolic.v  -  Testbench do array sistólico
// 
//  Roda duas "tiles" e compara cada acumulador com um golden model feito
//  direto no testbench (soma de produtos com inteiros de 64 bits):
//
//      Teste 1: K = 784   -> como a camada OCULTA  (W_in · x)
//      Teste 2: K = 128   -> como a camada de SAÍDA (β · h)
//
//  Obs.: estímulos são dados na borda de DESCIDA do clock para evitar
//  corridas (race conditions) com o DUT, que trabalha na borda de subida.

`timescale 1ns/1ps

module TbSystolic;

    // ---------------- Parâmetros ----------------
    localparam DW    = 16;
    localparam AW    = 40;
    localparam P     = 16;
    localparam K_MAX = 784;

    // ---------------- Clock e reset ----------------
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;                           // 100 MHz

    // ---------------- Sinais do DUT ----------------
    reg                 start = 1'b0;
    reg  [15:0]         K_atual = 16'd0;
    wire                busy, done;
    wire [15:0]         k_idx;
    reg  signed [DW-1:0] x_data;
    reg  [P*DW-1:0]     w_flat;
    wire [P*AW-1:0]     acc_flat;

    MatPreparar #(.DW(DW), .AW(AW), .P(P)) dut (
        .clk(clk), .rst(rst),
        .start(start), .K(K_atual), .busy(busy), .done(done),
        .k_idx(k_idx), .x_data(x_data), .w_data_flat(w_flat),
        .acc_flat(acc_flat)
    );

    // ---------------- Memórias comportamentais ----------------
    //  x_mem[k]            : vetor de entrada
    //  w_mem[j*K + k]      : peso do neurônio j para a entrada k
    //  Leitura síncrona (1 ciclo), como uma RAM de bloco da FPGA.
    reg signed [DW-1:0] x_mem [0:K_MAX-1];
    reg signed [DW-1:0] w_mem [0:P*K_MAX-1];

    integer j, k;
    wire [15:0] k_seguro = (k_idx < K_atual) ? k_idx : 16'd0;   // evita ler fora

    always @(posedge clk) begin
        x_data <= x_mem[k_seguro];
        for (j = 0; j < P; j = j + 1)
            w_flat[j*DW +: DW] <= w_mem[j*K_atual + k_seguro];
    end

    // ---------------- Uma rodada de teste ----------------
    integer erros_total = 0;

    task roda_teste(input integer K);
        integer ciclos, erros;
        reg signed [63:0]    ouro;
        reg signed [AW-1:0]  obtido;
        integer jj, kk;
        begin
            K_atual = K;

            // Dados aleatórios: x ~ pixel normalizado [0, 1.0], w ~ [-2.0, +2.0)
            for (kk = 0; kk < K; kk = kk + 1)
                x_mem[kk] = $urandom_range(0, 4096);
            for (kk = 0; kk < P*K; kk = kk + 1)
                w_mem[kk] = $urandom_range(0, 16383) - 8192;

            // Dispara
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;

            // Espera o fim, contando ciclos
            ciclos = 0;
            while (!done) begin @(negedge clk); ciclos = ciclos + 1; end

            // Confere cada PE
            erros = 0;
            for (jj = 0; jj < P; jj = jj + 1) begin
                ouro = 0;
                for (kk = 0; kk < K; kk = kk + 1)
                    ouro = ouro + x_mem[kk] * w_mem[jj*K + kk];
                obtido = acc_flat[jj*AW +: AW];
                if (obtido !== ouro[AW-1:0]) begin
                    erros = erros + 1;
                    $display("  ERRO PE%0d: obtido=%0d  esperado=%0d", jj, obtido, ouro);
                end
            end

            $display("K=%4d | ~%0d ciclos | erros=%0d | %s",
                     K, ciclos, erros, (erros == 0) ? "PASSOU" : "FALHOU");
            erros_total = erros_total + erros;
            repeat (3) @(negedge clk);
        end
    endtask

    // ---------------- Sequência principal ----------------
    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        roda_teste(784);   // como camada oculta
        roda_teste(128);   // como camada de saída

        $display("-------------------------------------");
        if (erros_total == 0) $display("DEU BOM");
        else                  $display("DEU RUIM");
        $finish;
    end

endmodule

\section{Thực nghiệm: Triển khai PoC và Đánh giá Các Giao thức}

\subsection{Mục tiêu thực nghiệm}

Mục tiêu của phần thực nghiệm là xây dựng và đo lường một bộ bằng chứng khái niệm (Proof-of-Concept – PoC) cho các giao thức hoán đổi nguyên tử chuỗi chéo, bao gồm:

\begin{itemize}
    \item HTLC truyền thống (2 bên),
    \item HTLC-GP (griefing-penalty cố định),
    \item HTLC-GP$\zeta$ (griefing-penalty tuyến tính có tối thiểu đảm bảo),
    \item MP-HTLC (đa bên dựa trên MPC+TSS, không penalty),
    \item MP-HTLC-LGP (đa bên + penalty tuyến tính LGP).
\end{itemize}

Mỗi PoC được thiết kế nhằm:
\begin{enumerate}
    \item So sánh chi phí on-chain (gas) giữa các biến thể HTLC / HTLC-GP / HTLC-GP$\zeta$ và MP-HTLC / MP-HTLC-LGP.
    \item Đo độ trễ end-to-end của từng giao thức, tách riêng phần on-chain và overhead do MPC/TSS off-chain.
    \item Mô phỏng và định lượng hành vi griefing: thời gian vốn bị khóa, penalty mà kẻ grief phải chịu, và mức độ bảo vệ kinh tế mà mỗi giao thức mang lại cho bên bị hại.:contentReference[oaicite:0]{index=0}
\end{enumerate}

\subsection{Môi trường và công cụ thực nghiệm}

\subsubsection{Hạ tầng blockchain và công cụ smart contract}

\begin{itemize}
    \item \textbf{Blockchain local:} sử dụng \texttt{anvil} (Foundry) làm EVM node chạy cục bộ, cho phép điều khiển thời gian (\texttt{evm\_increaseTime}) và mine block thủ công (\texttt{evm\_mine}).
    \item \textbf{Ngôn ngữ và framework:} toàn bộ hợp đồng được viết bằng Solidity, biên dịch và deploy thông qua Foundry:
    \begin{itemize}
        \item \texttt{forge script script/htlc-script.s.sol:htlc\_script},
        \item \texttt{forge script script/htlc-gp-script.s.sol:htlc\_gp\_script},
        \item \texttt{forge script script/htlc-gpz-script.s.sol:htlc\_gpz\_script},
        \item \texttt{forge script script/mp-htlc-script.s.sol:mp\_htlc\_script},
        \item \texttt{forge script script/htlc-lgp-script.s.sol:htlc\_lgp\_script}.
    \end{itemize}
    \item \textbf{Token thử nghiệm:} một contract ERC–20 \texttt{MockToken} được deploy cùng mỗi kịch bản, dùng làm tài sản hoán đổi.
\end{itemize}

\subsubsection{Thành phần off-chain MPC/TSS}

\begin{itemize}
    \item \textbf{Ngôn ngữ:} Go được sử dụng cho mô-đun MPC/TSS.
    \item \textbf{Nghi lễ TSS:} chương trình \texttt{go run main.go} thực hiện:
    \begin{enumerate}
        \item Distributed Key Generation (KEYGEN) để tạo khóa chung,
        \item sinh địa chỉ Ethereum ngưỡng (\texttt{TSS Ethereum Address}),
        \item tính \texttt{lockId} = \texttt{sha256(preimage)},
        \item sinh chữ ký ngưỡng \texttt{ethSig(65)} trên \texttt{lockId}.
    \end{enumerate}
    \item \textbf{Kết nối với on-chain:} đầu ra của chương trình TSS (\texttt{TSS\_SIGNER}, \texttt{LOCK\_ID}, \texttt{SIG}) được export vào môi trường shell và sử dụng trong các lệnh \texttt{cast} để gọi các hàm \texttt{lock}, \texttt{claimWithSig}, \texttt{refund} của MP-HTLC và MP-HTLC-LGP.
\end{itemize}

\subsection{Thiết kế kịch bản thực nghiệm theo từng giao thức}

\subsubsection{HTLC truyền thống}

Đối với HTLC hai bên, chúng tôi triển khai một hợp đồng \texttt{HTLC\_TRAD} chuẩn với các hàm \texttt{lock}, \texttt{claim}, \texttt{refund}. Preimage chung được cố định:

\begin{verbatim}
PREIMAGE = "super-secret-preimage"
LOCK_ID  = sha256(PREIMAGE)
\end{verbatim}

Cấu hình account:

\begin{itemize}
    \item \textbf{Sender (Alice):} account 1 của anvil,
    \item \textbf{Receiver (Bob):} account 0 của anvil,
    \item \textbf{Token:} \texttt{MockToken}, Alice được mint 1000 MTK.
\end{itemize}

Các kịch bản PoC:

\begin{enumerate}[label=\textbf{HTLC-\Alph*}]
    \item \textbf{Scenario A – Honest lock + claim sớm:}
    \begin{itemize}
        \item Alice \texttt{approve} 100 MTK cho \texttt{HTLC\_TRAD}.
        \item Alice gọi \texttt{lock(receiver, token, amount, LOCK\_ID, timelock)}, với \texttt{timelock = 1800s}.
        \item Bob gọi \texttt{claim(LOCK\_ID, PREIMAGE)} trước khi hết timelock.
    \end{itemize}
    Đối với mỗi bước, gas được lấy từ \texttt{cast receipt} và latency được đo bằng \texttt{time cast send ...}.

    \item \textbf{Scenario B – Lock + refund (receiver không claim):}
    \begin{itemize}
        \item Alice \texttt{lock} như trên.
        \item Không có giao dịch \texttt{claim}.
        \item Sau đó tăng thời gian bằng \texttt{evm\_increaseTime(1801)} và \texttt{evm\_mine}, rồi Alice gọi \texttt{refund(LOCK\_ID)}.
    \end{itemize}
    Scenario này đo chi phí gas của \texttt{lock} và \texttt{refund} khi receiver im lặng cho đến hết timelock.

    \item \textbf{Scenario C – Griefing trong HTLC truyền thống:}
    \begin{itemize}
        \item Quy trình giống Scenario B, nhưng được diễn giải dưới góc độ tấn công griefing: Bob cố ý không claim, khiến vốn của Alice bị khóa cho đến khi timelock hết hạn, trong khi Bob không chịu bất kỳ penalty on-chain nào.
        \item Thời gian vốn bị khóa được tính từ block \texttt{lock} đến block \texttt{refund}.
    \end{itemize}
\end{enumerate}

\subsubsection{HTLC-GP (griefing-penalty cố định)}

Hợp đồng \texttt{HTLC\_GP} mở rộng HTLC truyền thống với một trường \texttt{depositRequired} và hàm \texttt{confirmParticipation}.

\begin{itemize}
    \item \textbf{Tham số:}
    \begin{itemize}
        \item \texttt{AMOUNT} = 100 MTK,
        \item \texttt{TIMELOCK} = 1800s,
        \item \texttt{DEPOSIT\_REQUIRED} = 1 ETH,
        \item \texttt{DEPOSIT\_WINDOW} = 600s.
    \end{itemize}
\end{itemize}

Các kịch bản:

\begin{enumerate}[label=\textbf{GP-\Alph*}]
    \item \textbf{Scenario A – Honest: deposit + claim sớm (không penalty):}
    \begin{itemize}
        \item Alice \texttt{createLock(..., DEPOSIT\_REQUIRED, DEPOSIT\_WINDOW)}.
        \item Bob \texttt{confirmParticipation(LOCK\_ID)} kèm \texttt{value = DEPOSIT\_REQUIRED}.
        \item Bob \texttt{claim(LOCK\_ID, PREIMAGE)} trước \texttt{unlockTime}.
        \item Sau khi claim, deposit được refund đầy đủ cho Bob.
    \end{itemize}

    \item \textbf{Scenario B – Griefing: đã đặt cọc nhưng không claim, sender refund sau timelock:}
    \begin{itemize}
        \item Alice \texttt{createLock}, Bob \texttt{confirmParticipation}, nhưng không gọi \texttt{claim}.
        \item Sau \texttt{TIMELOCK}, Alice gọi \texttt{refund(LOCK\_ID)}.
        \item Token quay về Alice, toàn bộ \texttt{depositPaid} (1 ETH) được chuyển cho Alice, mô phỏng penalty cố định mà Bob phải chịu khi grief.
    \end{itemize}

    \item \textbf{Scenario C – Không confirm deposit, refund sau depositWindow (penalty = 0):}
    \begin{itemize}
        \item Alice chỉ \texttt{createLock}, Bob không gọi \texttt{confirmParticipation}.
        \item Sau khi \texttt{depositWindow} kết thúc, Alice có thể \texttt{refund} ngay, không nhận bất kỳ khoản penalty nào (do \texttt{depositPaid = 0}).
    \end{itemize}
\end{enumerate}

\subsubsection{HTLC-GP$\zeta$ (griefing-penalty tuyến tính)}

Hợp đồng \texttt{htlc\_gpz} bổ sung thêm tham số \texttt{timeBased} và logic penalty tuyến tính theo thời gian claim.

\begin{itemize}
    \item \textbf{Tham số:}
    \begin{itemize}
        \item \texttt{AMOUNT} = 100 MTK,
        \item \texttt{TIMELOCK} = 1800s,
        \item \texttt{TIMEBASED} = 600s (penalty window 10 phút cuối),
        \item \texttt{DEPOSIT\_REQUIRED} = 1 ETH,
        \item \texttt{DEPOSIT\_WINDOW} = 600s.
    \end{itemize}
\end{itemize}

Các kịch bản:

\begin{enumerate}[label=\textbf{GP$\zeta$-\arabic*}]
    \item \textbf{Scenario 1 – Claim sớm, trước penalty window (penalty = 0):}
    Bob claim khi \texttt{block.timestamp < unlockTime - timeBased}. Receiver nhận đủ token và được hoàn lại toàn bộ deposit (trừ gas).

    \item \textbf{Scenario 2 – Claim trong penalty window (0 < penalty < deposit):}
    Sau khi \texttt{createLock + confirmParticipation}, hệ thống tăng thời gian vào giữa khoảng \texttt{[unlockTime - timeBased, unlockTime)}. Khi Bob claim:
    \begin{itemize}
        \item token chuyển cho Bob,
        \item deposit được chia thành hai phần: \texttt{penalty} chuyển cho Alice, phần còn lại \texttt{depositBack} trả lại Bob,
        \item penalty xấp xỉ tuyến tính với thời gian trễ.
    \end{itemize}

    \item \textbf{Scenario 3 – Claim rất trễ, sát unlockTime (penalty \ensuremath{\approx} full deposit):}
    Bob claim rất gần \texttt{unlockTime}, penalty gần bằng \texttt{DEPOSIT\_REQUIRED}. Đây là trường hợp minh họa “griefing toán học”: càng claim trễ, receiver gần như mất toàn bộ cọc.

    \item \textbf{Scenario 4 – Không confirm deposit, refund sau depositWindow (penalty = 0)} và \textbf{Scenario 5 – Confirm deposit nhưng không claim, refund sau timelock (penalty = deposit)} được thiết kế tương tự HTLC-GP, nhằm so sánh trực tiếp hai mô hình phạt.
\end{enumerate}

\subsubsection{MP-HTLC (đa bên, không penalty)}

MP-HTLC được triển khai trên cùng một chain EVM với 3 bên tham gia:

\begin{itemize}
    \item P1, P2, P3 là 3 account mặc định của anvil,
    \item Preimage và \texttt{LOCK\_ID} được sinh từ module TSS off-chain,
    \item Mỗi bên mint và approve một lượng \texttt{MockToken} khác nhau:
    \begin{itemize}
        \item Leg 1: P1 \textrightarrow{} P2, 100 MTK,
        \item Leg 2: P2 \textrightarrow{} P3, 200 MTK,
        \item Leg 3: P3 \textrightarrow{} P1, 300 MTK.
    \end{itemize}
\end{itemize}

Tất cả các leg dùng chung \texttt{LOCK\_ID}, tạo thành một vòng hoán đổi đa bên. PoC tập trung vào:

\begin{itemize}
    \item Gas của hàm \texttt{lock} cho từng leg,
    \item Độ trễ on-chain khi tất cả các leg được mở và claim diễn ra sử dụng cùng preimage,
    \item Hành vi khi một bên không tham gia claim (griefing ở mức độ đa bên, nhưng không có cơ chế penalty on-chain).
\end{itemize}

\subsubsection{MP-HTLC-LGP (đa bên + penalty tuyến tính LGP)}

MP-HTLC-LGP kết hợp kiến trúc đa bên của MP-HTLC với cơ chế deposit và penalty tuyến tính tương tự HTLC-GP$\zeta$, nhưng được điều khiển bởi TSS:

\begin{itemize}
    \item Tài sản ban đầu được mint cho địa chỉ \texttt{ADDR\_TSS}, sau đó \texttt{ADDR\_TSS} approve cho \texttt{ADDR\_HTLC}.
    \item Receiver (acc0) nộp deposit thông qua \texttt{confirmParticipation(LOCK\_ID)}.
    \item \texttt{LOCK\_ID} và \texttt{SIG} (chữ ký TSS) được export từ chương trình Go.
\end{itemize}

Các kịch bản chính:

\begin{enumerate}[label=\textbf{LGP-\arabic*}]
    \item \textbf{Scenario 1 – Claim sớm bằng \texttt{claimWithSig}, penalty = 0:} receiver claim trước penalty window, nhận đầy đủ token và deposit.

    \item \textbf{Scenario 2 – Claim trong penalty window:} sau khi tăng thời gian, receiver gọi \texttt{claimWithSig(LOCK\_ID, PREIMAGE, SIG)}; hợp đồng tính toán penalty tuyến tính và phân phối lại deposit.

    \item \textbf{Scenario 3 – Không claim, refund sau timelock:} deposit đã confirm nhưng receiver im lặng, \texttt{refund} chuyển toàn bộ deposit cho TSS signer (đại diện tập thể các bên), mô phỏng trường hợp griefing bị phạt tối đa.

    \item \textbf{Scenario 4 – Không confirm deposit, refund sau depositWindow:} giống HTLC-GP$\zeta$, cho phép đánh giá nhánh không có penalty.
\end{enumerate}

\subsection{Chỉ số đánh giá và phương pháp đo lường}

Dựa trên định hướng Section 5.4 của tài liệu gốc, chúng tôi tập trung vào ba nhóm chỉ số chính:​:contentReference[oaicite:1]{index=1}

\subsubsection{Chi phí on-chain (gas)}

\begin{itemize}
    \item Đối với mỗi giao thức và mỗi hàm quan trọng:
    \begin{itemize}
        \item HTLC/HTLC-GP/HTLC-GP$\zeta$: \texttt{approve}, \texttt{lock/createLock}, \texttt{confirmParticipation}, \texttt{claim}, \texttt{refund}.
        \item MP-HTLC/MP-HTLC-LGP: \texttt{lock}, \texttt{confirmParticipation}, \texttt{claimWithSig}, \texttt{refund}.
    \end{itemize}
    \item Mỗi lệnh \texttt{cast send} đều lưu lại \texttt{TX\_HASH}, sau đó dùng \texttt{cast receipt} để trích xuất trường \texttt{gasUsed}.
    \item Mỗi phép đo được lặp lại $N$ lần (ví dụ, $N=10$) với cùng cấu hình, sau đó tính trung bình và độ lệch chuẩn để giảm nhiễu do biến động gas.
\end{itemize}

\subsubsection{Độ trễ end-to-end}

\begin{itemize}
    \item \textbf{On-chain latency:} đo bằng \texttt{time cast send ...}, bao gồm cả thời gian gửi, xử lý và được mine trên \texttt{anvil}.
    \item \textbf{Tổng latency MP-HTLC / MP-HTLC-LGP:}
    \begin{itemize}
        \item \texttt{t\_TSS\_sign}: thời gian chạy \texttt{go run main.go} từ khi bắt đầu nghi lễ ký cho đến khi sinh ra \texttt{ethSig(65)},
        \item \texttt{t\_onchain}: thời gian \texttt{time cast send claimWithSig(...)} trên EVM,
        \item \texttt{t\_total = t\_TSS\_sign + t\_onchain}.
    \end{itemize}
    \item Các phép so sánh quan trọng:
    \begin{itemize}
        \item \texttt{t\_onchain\_trad} vs. \texttt{t\_onchain\_lgp} để đo overhead do logic contract phức tạp hơn,
        \item \texttt{t\_total\_lgp} vs. \texttt{t\_onchain\_trad} để lượng hóa chi phí thêm do TSS off-chain.
    \end{itemize}
\end{itemize}

\subsubsection{Chỉ số griefing và penalty}

Để đánh giá mức độ bảo vệ trước tấn công griefing:

\begin{itemize}
    \item Với HTLC truyền thống:
    \begin{itemize}
        \item \texttt{t\_lock\_to\_refund} = thời gian từ \texttt{lock} đến \texttt{refund},
        \item \texttt{cost\_sender = gas\_lock + gas\_refund},
        \item \texttt{penalty\_receiver = 0}.
    \end{itemize}
    \item Với HTLC-GP / HTLC-GP$\zeta$ / MP-HTLC-LGP:
    \begin{itemize}
        \item ghi lại \texttt{penalty\_paid} cho sender (từ event hoặc log) tương ứng với độ trễ,
        \item quan sát sự thay đổi của \texttt{penalty} theo thời gian delay trong penalty window,
        \item so sánh với \texttt{depositRequired} để xác định mức độ răn đe.
    \end{itemize}
\end{itemize}

\subsection{Tổ chức dữ liệu và trực quan hóa (dự kiến)}

Dữ liệu thu được từ các PoC CLI sẽ được lưu dưới dạng bảng CSV với cấu trúc chung:

\begin{verbatim}
protocol, fn, scenario, gasUsed, t_onchain, t_TSS_sign, t_total,
timelock, timeBased, depositRequired, N_parties, delay
\end{verbatim}

Từ đó, có thể xây dựng các bảng và biểu đồ sau (các giá trị cụ thể sẽ được bổ sung sau khi chạy đo thực nghiệm):

\begin{itemize}
    \item Bảng so sánh gas trung bình cho từng hàm và từng giao thức.
    \item Biểu đồ \texttt{gas} vs. \texttt{số lượng leg} (2 bên vs. đa bên).
    \item Biểu đồ \texttt{t\_onchain} và \texttt{t\_total} cho HTLC truyền thống vs. MP-HTLC-LGP.
    \item Biểu đồ \texttt{penalty} vs. \texttt{delay claim} cho HTLC-GP$\zeta$ và MP-HTLC-LGP, so sánh với đường penalty = 0 của HTLC truyền thống.
\end{itemize}

Phần kết quả chi tiết (số liệu, bảng, biểu đồ) sẽ được trình bày riêng trong mục \emph{Kết quả và thảo luận}; ở đây, chúng tôi tập trung mô tả thiết kế thực nghiệm, cách cấu hình môi trường, tổ chức kịch bản PoC và phương pháp đo lường, để đảm bảo quá trình đánh giá các giao thức có thể được tái lập một cách minh bạch.
